# Conseil des agents — R1 : Performance, légèreté, exploitation de WebKit

Périmètre lu : README, Void/Browser, Void/Web, Void/UI, Features/AdBlock, Features/Library, App/*, Resources/Scripts/*.js, plus ElementHider, DownloadManager et WebKitSPI. Lecture seule, aucun fichier du dépôt modifié. Rien n'a été compilé ni chronométré : les coûts ci-dessous sont raisonnés à partir du code, pas mesurés. Là où je ne suis pas sûr d'un fait WebKit, je l'écris « à vérifier ».

## Verdict général

L'architecture est saine pour un navigateur de 5 000 lignes :
- `@Observable` (Observation) au lieu d'un `ObservableObject` géant, donc suivi par propriété. Il n'y a pas de tempête de re-rendus globale.
- Un seul `WKUserContentController` partagé, un monde JS isolé.
- Onglets endormis avec `interactionState`, et seul l'onglet visible a une vue web au lancement.
- Un unique timer (60 s) dans toute l'app, pas de polling.
- `WKContentRuleList` compilée et mise en cache par identifiant.

Les vrais coûts sont ailleurs : SQLite et suggestions sur le thread principal, un `querySelectorAll('*')` dans `media.js`, un blocage qui se désactive pendant la recompilation, et un chargement immédiat des onglets d'arrière-plan.

## 1. Coûts cachés

### A. Suggestions de la barre de commande : SQL sur le main thread, à chaque rendu (le plus net)
- `UI/CommandBar.swift:88` : `let suggestions = SuggestionEngine.suggestions(for: text, browser: browser)` est évalué dans `body`. Il tourne donc à chaque frappe, mais aussi à chaque changement de `selection`.
- `UI/CommandBar.swift:120` : `.onHover { if $0 { selection = index } }` modifie `@State selection`, ce qui réévalue `body`, donc relance `suggestions(...)`. Chaque survol d'une ligne exécute 2 requêtes SQLite plus le parcours de tous les onglets, favoris et téléchargements.
- `Features/Library/HistoryStore.swift:44-47` : `WHERE url LIKE '%q%' OR title LIKE '%q%'` est un scan complet de la table, sans index utile, sur le main thread. Avec 100 000 URL (surtout après un import Chrome/Arc) c'est probablement plusieurs dizaines de ms par frappe.
- `Suggestion.id = UUID()` (`CommandBar.swift:11`) change à chaque évaluation. SwiftUI considère donc que toutes les lignes sont nouvelles et les recrée : le `ForEach` (ligne 117) perd l'identité et la ligne survolée est reconstruite pendant le survol.
- Correctif : calculer les suggestions dans un `@State` mis à jour par `.onChange(of: text)` (avec un debounce court), ne pas les recalculer sur `selection`, utiliser des ids stables (`url.absoluteString` ou kind+clé), et limiter la requête (préfixe d'hôte d'abord, `LIKE` complet seulement si peu de résultats).

### B. SQLite : commit synchrone à chaque page et à chaque changement de titre
- `SQLiteDB.swift:9-15` n'active ni `journal_mode=WAL` ni `synchronous=NORMAL`. Chaque `execute` hors transaction est un commit avec fsync (mode journal par défaut).
- `TabWebDelegate.swift:85` : `HistoryStore.record` à chaque `didFinish`, sur le main thread. C'est un INSERT ON CONFLICT avec fsync.
- `Tab.swift:197` : `HistoryStore.updateTitle` à chaque KVO `title`. Sur les SPA (YouTube, GitHub, Gmail) le titre change souvent, donc un UPDATE avec fsync par changement, sur le main thread.
- `HistoryStore.init` (lignes 18-25) est paresseux : la connexion s'ouvre et `CREATE TABLE/INDEX IF NOT EXISTS` s'exécute au premier `didFinish` du premier chargement, en plein chargement de page.
- Correctif : `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;` à l'ouverture, écritures groupées sur une queue série dédiée (une seule connexion, confinée à cette queue), et ouverture de la base préchauffée au lancement en arrière-plan.

### C. JS injecté dans chaque frame (WebViewFactory.swift:14-19)
Quatre scripts (`core`, `media`, `autofill`, `activity`, ≈ 15 Ko) sont injectés avec `forMainFrameOnly: false`, donc évalués dans chaque iframe (pubs, widgets, embeds). Le coût est surtout dans :
- **`media.js:19-21` `videos()`** : s'il n'y a aucune `<video>` dans le DOM léger, il retombe sur `collect(document, [], 3)`, qui fait `root.querySelectorAll('*')` sur tout le DOM pour chercher des `shadowRoot` (ligne 15).
- **`media.js:112-125`** : cette fonction est appelée depuis un `MutationObserver` `{childList, subtree}` sur `documentElement`, qui rappelle `announce()` à chaque lot de mutations pendant 30 s. Chaque rappel, sur une page sans vidéo (donc la majorité), parcourt tout le DOM. Sur une page dynamique (fil infini, SPA) c'est un coût CPU continu pendant 30 s, dans chaque frame.
- Correctif : `getElementsByTagName('video')` d'abord (index live, quasi gratuit) ; ne faire la recherche shadow DOM qu'une fois après `load`, ou seulement quand un `<video>` est signalé ; dans le callback, filtrer `addedNodes` (`node.tagName === 'VIDEO'` ou `node.querySelector('video')` sur les nœuds ajoutés uniquement). Le cas des `<video>` dans un shadow root ouvert peut être couvert par un seul balayage différé.
- `core.js:33-42` : `MutationObserver` sur tout le document pour patcher les iframes. Il boucle sur `addedNodes` et fait `querySelectorAll('iframe')` pour chaque nœud ajouté qui a des enfants. C'est acceptable, mais réductible à `getElementsByTagName('iframe')` sur les nœuds ajoutés, ou à `document.getElementsByTagName('iframe')` à la volée.
- `autofill.js:77-…` : `MutationObserver` avec debounce de 400 ms. Acceptable. `activity.js` : debounce de 100 ms sur le scroll, passif. Correct.
- Fusionner les 4 scripts en un seul `WKUserScript` réduirait le nombre d'évaluations par frame. Gain faible, à ne faire qu'après le point précédent.

### D. Adblock : la protection saute pendant la recompilation
- `ContentRules.swift:51` : `if let adBlockList { ucc.remove(adBlockList) }` est exécuté avant la compilation (ligne 58). Pendant la recompilation, aucune liste n'est active. Après un changement de liste blanche, ou un jour avec une grosse liste, les pages chargées entre-temps ne sont pas filtrées.
- Il faut ajouter la nouvelle liste, puis retirer l'ancienne.
- `ContentRules.swift:56-57` : `encodedRules()` construit le JSON complet (150 règles, `JSONSerialization` + hash FNV sur ~30 Ko) sur le main thread à chaque lancement, avant même de savoir si la liste est en cache. Avec 100 000 règles ce serait inacceptable. À mémoriser : l'identifiant de la dernière liste compilée dans `UserDefaults`, et au démarrage ne faire que `store.contentRuleList(forIdentifier:)`.
- Fuite sur disque : `WKContentRuleListStore` n'est jamais nettoyé (`removeContentRuleList` = 0 occurrence dans le code). Chaque changement de liste blanche, chaque masquage d'élément (⌘⇧H) et chaque bump de `version` laisse un fichier compilé orphelin dans `~/Library/WebKit/<bundle>/…/ContentRuleLists`. Prévoir `getAvailableContentRuleListIdentifiers` puis `removeContentRuleList` pour tout identifiant `void-*` non actif.

### E. Persistance de session sur le main thread
- `BrowserModel.swift:437-448` `saveNow()` : encode en JSON toutes les favicons PNG (32 px, base64 dans le JSON) de tous les onglets, et `StateStore.save` écrit de façon atomique, sur le main thread. `setNeedsSave()` est appelé à chaque sélection, chaque `url` KVO et chaque `didFinish` (debounce 1 s).
- Pour 100 onglets c'est environ 0,3 à 0,5 Mo de JSON : quelques ms, pas dramatique. Mais c'est facile à sortir du thread principal, et les favicons gagneraient à être stockées à part (cache par hôte), pas dans `session.json`.
- `StateStore.load()` (au lancement, `BrowserModel.swift:121`) décode ce même JSON de façon synchrone avant l'affichage de la fenêtre.

### F. Favicons
- `FaviconLoader.swift:8` : cache `[String: (NSImage, Data)]` en mémoire seulement, jamais persisté ni borné. À chaque lancement, chaque hôte déjà vu repasse par un `voidCall` JS (`querySelectorAll` des `<link rel=icon>`) plus 1 à 3 requêtes réseau, sans timeout explicite (`URLSession.data`, timeout par défaut de 60 s).
- Le redimensionnement (`voidResizedPNG`) tourne sur le main actor. Petit (32 px) mais gratuit à déplacer.

### G. Onglets d'arrière-plan
- `BrowserModel.swift:165` : `openTab(background: true)` appelle `tab.ensureWebView()` tout de suite, ce qui charge la page. Un ⌘-clic répété (ou « Tout ouvrir ») crée autant de processus WebContent (souvent 50 à 150 Mo chacun) que de clics, et ils restent jusqu'aux 30 minutes de veille.
- Alternative : laisser l'onglet endormi avec son URL et ne le charger qu'à la sélection, ou plafonner le nombre de préchargements.
- Il n'y a pas non plus de réaction à la pression mémoire (`DispatchSource.makeMemoryPressureSource`) : la mise en veille n'est déclenchée que par l'inactivité de 30 min (`BrowserModel.swift:85`, `sleepInactiveTabs` toutes les 60 s via `BrowserWindows.swift:35`). Sous pression mémoire, il serait cohérent de réveiller la même logique avec un délai réduit (par ex. 5 min).

### H. Re-rendus SwiftUI (mesurés au code, pas au profileur)
- Points plutôt sains : `Tab`, `Space`, `BrowserModel`, `AppSettings` sont `@Observable`, donc chaque vue ne réagit qu'aux propriétés lues. `ProgressLine` (`PageView.swift:65`) et `ReadingProgressFill` (`TabViews.swift:293`) sont des sous-vues séparées qui lisent `progress` seules : la progression de chargement (KVO `estimatedProgress`, `Tab.swift:209`) et le défilement (throttlés à 100 ms et 0,4 % dans `activity.js` et `ScriptMessageRouter.swift:25`) ne réévaluent pas les grosses vues.
- `Space.selectedTab` (`Space.swift:52-53`) fait `pinned + tabs` (allocation d'un tableau) puis `first { id == … }`. C'est appelé dans quasiment chaque `body` (`browser.selectedTab` dans `PageView`, `AddressPill`, `SidebarView`…). Négligeable jusqu'à quelques dizaines d'onglets, linéaire au-delà. Un `[UUID: Tab]` ou un `selectedTab` stocké règle le problème.
- `SidebarView.body` (`SidebarView.swift:15-17`) lit `browser.selectedTab?.canGoBack`, `canGoForward`, `isLoading`, donc se réévalue à chaque navigation (deux fois par chargement). Ses enfants reçoivent des références de classe, donc ne sont pas recréés. Impact faible.
- Le `matchedGeometryEffect` sur l'onglet sélectionné (`TabViews.swift:~171`) et les `.animation(..., value: hovering)` par ligne sont OK, mais avec plusieurs centaines d'onglets la barre latérale (`LazyVStack`) devient le premier point à profiler.
- `BrowserModel.keepAliveTabs` (`BrowserModel.swift:139`) parcourt tous les onglets à chaque réévaluation de `WebHost.desired` (via `withObservationTracking`, `WebHost.swift:48-62`). O(n), négligeable.

### I. Divers
- `WebViewFactory.swift:24-27` `userAgentSuffix` lit l'`Info.plist` de `/Applications/Safari.app` de façon synchrone à la première création de vue web. Petit coût disque, mémoïsé (`static let`), mais sur le chemin critique du premier chargement.
- `WebViewFactory.voidCall` (ligne 93) arme un `asyncAfter` de 5 s par appel JS, y compris quand l'appel a déjà répondu : inoffensif mais inutile ; `Task.sleep` annulable ou un timer annulé à la réponse suffirait.
- Le processus WebContent redémarre avec un simple `reload()` en cas de crash (`TabWebDelegate.swift:108-110`) : à cadrer contre une boucle si la page crashe systématiquement.

## 2. Démarrage à froid

Ordre réel d'après le code :
1. `VoidApp` : `BrowserModel.shared` (static) : `StateStore.load()` lit et décode `session.json` (favicons comprises) de façon synchrone (`BrowserModel.swift:121`). `AppSettings.shared` : ~25 lectures `UserDefaults`, négligeable.
2. Création de la scène SwiftUI, `BrowserWindowView`, `WindowAccessor.configure` (`setFrameAutosaveName`, etc.).
3. `applicationDidFinishLaunching` (`AppDelegate.swift`) : `applyAppearance`, `BrowserWindows.start()` (timer 60 s + observer), `ContentRules.start()`, éventuellement `ExtensionManager.loadInstalled()` (macOS 15.4+ et option activée), puis onboarding au premier lancement.
4. `ContentRules.start()` construit le JSON de règles, calcule le hash, et interroge le store. En parallèle, `PageView.onChange(initial: true)` (`PageView.swift:59-61`) appelle `ensureWebView()` sur l'onglet sélectionné : création du `WKUserContentController` (chargement des 4 scripts du bundle), `WKWebsiteDataStore(forIdentifier:)`, lecture de l'Info.plist de Safari, puis `ContentRules.whenReady { load }` (`Tab.swift:119-121`) : le chargement de la page attend la liste (au plus 0,5 s, `ContentRules.swift:25`).
5. Premier `didFinish` : ouverture de `history.sqlite`, `CREATE INDEX IF NOT EXISTS`, INSERT (voir 1.B), `FaviconLoader.load` (JS + réseau).

Ce qui est bien : un seul onglet est chargé au lancement (README : « seul l'onglet visible reçoit une vue web »), les onglets épinglés restent endormis, l'historique et les favoris sont paresseux.

Ce qui pourrait être différé ou sorti du chemin critique :
- **Le blocage de la première page** : la seule attente réelle avant le premier chargement est `whenReady`. Avec la liste maison en cache elle est courte. Avec une grosse liste il faut ne dépendre que de `contentRuleList(forIdentifier:)` (pas de construction de JSON, pas de hash) ; en cas d'absence de cache, garder la liste maison compilée (petite) comme repli immédiat, et brancher la grosse quand elle est prête. Attention : une liste ajoutée après coup au `ucc` ne s'applique pas aux pages déjà chargées (ni aux requêtes déjà parties).
- **`StateStore.load` / décodage des favicons** : décoder le JSON hors du chemin de création de la fenêtre (les favicons peuvent arriver après l'affichage des onglets, des lettres suffisent quelques ms).
- **`HistoryStore` / `BookmarkStore` / `ElementHider`** : tous lisent des fichiers ou ouvrent SQLite sur le main thread à leur première utilisation. Préchauffer en tâche de fond après le premier affichage.
- **`ExtensionManager.loadInstalled()`** : déjà conditionné à l'option, ne rien changer.
- **Pas de restauration d'historique de navigation** : au relancement, chaque onglet ne revient que par URL (`SavedTab` ne contient pas `interactionState`, `StateStore.swift:19-24`). Persister l'état d'interaction de l'onglet visible (voir 3) serait un gain fonctionnel autant que perçu.

## 3. APIs WebKit / macOS sous-exploitées

Déjà utilisé (vérifié par grep) : `pageZoom` (`BrowserModel+Actions.swift:24`, par onglet, non persisté), `interactionState` (uniquement veille automatique, `Tab.swift:119,164`), `WKDownload` + `WKDownloadDelegate` (`DownloadManager`), `underPageBackgroundColor = .clear` (`WebViewFactory.swift:67`), `printOperation` (`Actions.swift:71`), `WKFindConfiguration` + `find(_:configuration:)` (`Actions.swift:60-64`), `cameraCaptureState/microphoneCaptureState` (`Tab.swift:187`), `WKContentRuleListStore` (compilation + cache), `WKWebsiteDataStore(forIdentifier:)` et `.nonPersistent()`, `WKContentWorld`, `WKWebExtension` (15.4+), `isInspectable`, `isElementFullscreenEnabled`, `isFraudulentWebsiteWarningEnabled`, `shouldPerformDownload`, `callAsyncJavaScript`. Le SPI (PiP, inspecteur) est encapsulé et gardé par `responds(to:)`.

Pas utilisé du tout (0 occurrence) et à fort rapport valeur/code :

| API | Apport | Effort |
|---|---|---|
| `pageZoom` par site (persisté) | Le zoom n'est ni mémorisé par hôte ni restauré après veille/relance. Table `[host: Double]` dans `AppSettings` ou un JSON, appliquée à `didCommit` (et après réveil). | ~40 lignes |
| `interactionState` persisté | Sérialiser `webView.interactionState` (c'est un `Data` sous le capot ; à vérifier) dans `SavedTab` pour l'onglet visible et les épinglés : historique avant/arrière et position de défilement retrouvés après relance, sans recharger l'historique à la main. | ~30 lignes + migration `SavedState.version` |
| `WKWebView.themeColor` (public, macOS 12+, observable KVO ; à vérifier) et `underPageBackgroundColor` | Teinter la barre latérale ou l'encadré de la page avec la couleur du site (`<meta name="theme-color">`), ou au moins régler le fond de rebond sur `themeColor` au lieu de `.clear`. Effet visuel fort pour un navigateur « qui s'efface ». | ~30 lignes |
| `WKWebsiteDataStore.fetchDataRecords(ofTypes:)` + `removeData(ofTypes:for:)` | Panneau « Données du site » par espace (cookies, cache, stockage local) ; le README n'a que « Fenêtres privées » et la suppression d'un espace entier. Utile pour la confidentialité et la libération de disque. | ~80 lignes de vue |
| `requestMediaPlaybackState`, `pauseAllMediaPlayback`, `setAllMediaPlaybackSuspended` (macOS 12+) | « Couper le son / pauser les autres onglets quand un nouveau lance une vidéo » sans passer par `media.js`. Réduit aussi la dépendance au JS pour l'état de lecture. | ~30 lignes |
| `createPDF(configuration:)` / `createWebArchive` | « Enregistrer en PDF » et « Enregistrer la page » en quelques lignes (l'impression passe déjà par `printOperation`). | ~30 lignes |
| `WKHTTPCookieStore` (observer + `deleteCookie`) | Purge des cookies tiers de traçage à la fermeture, sans règles supplémentaires. | ~40 lignes |
| `WKWebViewConfiguration.upgradeKnownHostsToHTTPS` (à vérifier, macOS 14.5 ou 15) | HTTPS d'abord, un booléen. | 1 ligne + réglage |
| `WKWebsiteDataStore.proxyConfigurations` (macOS 14) | Proxy ou VPN par espace. | ~40 lignes |
| `WKNavigationDelegate.webView(_:didReceive:)` (challenge d'authentification) | À vérifier : je n'ai pas trouvé son implémentation dans `TabWebDelegate` ; si absent, les pages en authentification HTTP Basic/Digest et certificat client échouent sans invite. | ~30 lignes |
| `WKUIDelegate.requestMediaCapturePermissionFor` | Permissions caméra/micro mémorisées par site (aujourd'hui l'invite WebKit par défaut, `TabWebDelegate.swift:168`). | ~40 lignes |

Non exploitable ou à écarter :
- **Web Push (macOS 14+)** : il exige l'entitlement `aps-environment` (compte développeur), or Void est signé « ad hoc » (README) : bloqué tant qu'il n'y a pas d'équipe.
- **`WKFindInteraction`** : iOS uniquement ; sur macOS la recherche actuelle (`WKFindConfiguration`) est la bonne API.
- **WebKit pour SwiftUI (`WebView`/`WebPage`, macOS 26)** : ne pas migrer, elle exclut macOS 14-15 et Void a besoin du SPI et de `WKWebView`.
- `WKURLSchemeHandler` : utile pour une page `void://` (page nouvel onglet, page d'erreur chargée par `loadSimulatedRequest`), mais le SwiftUI actuel suffit ; pas prioritaire.

## 4. Le bloqueur : de ≈150 règles à EasyList/uBO

### Contraintes WebKit à connaître
- 150 000 règles maximum par liste. Plusieurs listes peuvent être ajoutées au même `WKUserContentController`, chacune avec sa propre limite.
- Le format Safari ne connaît pas `|`, les lookaheads, ni les groupes complexes : les règles `regex` ou avec alternance sont à supprimer ou à développer. Le code actuel le respecte déjà (`AdBlockList.swift:39`).
- Pas de scriptlets ni de `$redirect`/`$removeparam` (`##+js(...)`) : à laisser tomber (ou petit JS séparé, plus tard) ; c'est ce qui empêche le blocage des pubs vidéo YouTube (README : « non implémenté »).
- `ignore-previous-rules` (utilisé pour la liste blanche, `AdBlockList.swift:74-79`) n'agit que dans la même liste. Les exceptions EasyList `@@||...` doivent donc être placées après les règles qu'elles annulent, dans la même liste.
- **Conséquence pour la liste blanche par site** : aujourd'hui l'`if-domain` est intégré à la liste et son changement recompile tout (`ContentRules.swift:56-58`). Avec 100 000 règles, cette recompilation coûterait de l'ordre de plusieurs secondes (à mesurer) à chaque bascule du bouclier. Comme l'identifiant de cache dépend du hash de la liste blanche, une liste déjà rencontrée revient du cache ; sinon compiler en tâche de fond et garder l'ancienne liste active (voir 1.D), recharger l'onglet ensuite.
- Attention à la mémoire : le bytecode d'une grosse liste est mappé dans les processus WebKit ; ordre de grandeur à mesurer (dizaines de Mo).

### Recommandation : conversion au premier lancement (téléchargement + conversion en tâche de fond), pas au build
- **Pourquoi pas au build** : le README revendique ≈ 5 Mo. Un JSON de règles Safari de 60 000+ règles pèse 5 à 10 Mo brut (1 à 2 Mo compressé) ; l'embarquer double la taille de l'app et fige les listes (EasyList change plusieurs fois par jour). Garder au build uniquement la petite liste actuelle comme repli hors ligne.
- **Au premier lancement, puis toutes les 24 à 72 h** :
  1. Télécharger `https://easylist.to/easylist/easylist.txt` (j'ai vérifié : répond 200), `easyprivacy.txt`, et éventuellement une liste française (Liste FR / AdblockFR, URL à confirmer) en `URLSession` avec `If-None-Match`/`ETag`, sur une `NSBackgroundActivityScheduler` pour ne pas réveiller l'app pour rien. Stocker dans `~/Library/Application Support/Void/lists/`.
  2. Convertir en Swift dans un `actor` dédié (jamais sur `@MainActor`) : un petit convertisseur maison de ~300 lignes, cohérent avec « aucune dépendance ».
  3. Compiler en 2 ou 3 listes séparées (réseau, cosmétique par domaine, cosmétique générique réduite) avec `compileContentRuleList`, identifiant = hash des ETag, avant d'ajouter la nouvelle puis de retirer l'ancienne.
  4. Mémoriser l'identifiant actif dans `UserDefaults` pour que le démarrage suivant ne fasse qu'un `contentRuleList(forIdentifier:)`.
- **Alternative « prête à l'emploi »** : des projets publient déjà du JSON au format Safari (AdGuard « SafariConverterLib »/filtres iOS, Brave). Je n'ai pas pu confirmer une URL stable (l'URL `filters.adtidy.org/ios/filters/2_optimized.json` que j'ai essayée renvoie 404) ni la licence du convertisseur AdGuard (à vérifier avant de l'embarquer ou de s'en inspirer, elle pourrait être incompatible). Faire soi-même le convertisseur est plus sûr.

### Règles du convertisseur (minimum utile)
- `||example.com^` : `url-filter` `^[^:]+://+([^/:]+\.)?example\.com[:/]` (le format déjà utilisé, `AdBlockList.swift:82`).
- `$third-party` : `load-type: ["third-party"]`.
- `$script,image,stylesheet,xmlhttprequest,subdocument,media,font,websocket,ping,popup` : `resource-type` (noms exacts à vérifier dans la documentation WebKit : `document`, `image`, `style-sheet`, `script`, `font`, `raw`, `svg-document`, `media`, `popup`, et selon la version `fetch`, `ping`, `websocket`).
- `$domain=a.com|~b.com` : `if-domain` / `unless-domain`.
- `@@…` : `ignore-previous-rules`, placé après.
- Cosmétique : `##.selector` générique regroupé en une seule règle `css-display-none` (comme aujourd'hui, `AdBlockList.swift:70-72`) ; `site.com##.selector` : `if-domain`. Les `#@#` deviennent des `unless-domain`.
- Rejeter les règles non convertibles (regex avec alternance, `$removeparam`, `$csp`, scriptlets, `:has()`/`:-abp-*`/`:xpath()` non supportés).
- Dédupliquer, trier (bloquer d'abord, exceptions ensuite), tronquer à 150 000 par liste.

### Point de vigilance sur la performance cosmétique
Les milliers de sélecteurs génériques d'EasyList (`##.ad-banner`…) en `css-display-none` sur toutes les pages alourdissent le calcul de style de chaque page. Ne charger qu'un sous-ensemble générique (quelques centaines), et tous les sélecteurs par domaine (leur coût est nul hors du domaine).

### Effet sur le reste du code
- `ContentRules.swift:25` (repli à 0,5 s) reste valable ; le README doit passer « ≈ 150 règles » à « EasyList + EasyPrivacy » seulement si vérifié par l'auto-test.
- `ElementHider` (⌘⇧H) est une liste séparée (`void-hidden`), donc indépendante ; garder.
- `AppSettings.adBlockAllowlist` (`AppSettings.swift:73-74`) déclenche `ContentRules.shared.reload()` à chaque modification : à débouncer (les `didSet` de `adBlockEnabled` et de la liste blanche peuvent chacun lancer une compilation).

## 5. TOP 5 des chantiers pour cette nuit

Chaque chantier est réalisable seul en quelques heures et vérifiable par build (`xcodebuild`, hors iCloud d'après la mémoire du projet) + `Void.app/Contents/MacOS/Void -VoidSelfTest features`.

1. **Base SQLite et suggestions sans blocage du main thread.**
   - `SQLiteDB` : WAL + `synchronous=NORMAL` à l'ouverture, ouverture de `HistoryStore` préchauffée au lancement, écritures `record`/`updateTitle` groupées sur une queue série.
   - `CommandBar` : suggestions stockées dans un `@State`, calculées dans `onChange(of: text)`, ids stables, pas de recalcul sur `selection`.
   - Vérification : nouveau test « features » qui remplit une base temporaire de 50 000 URL, mesure le temps de `SuggestionEngine.suggestions`, et vérifie que le survol ne relance pas le calcul (compteur d'appels).

2. **Corriger `media.js` (parcours DOM complet) et `core.js`.**
   - `getElementsByTagName('video')` d'abord, recherche shadow DOM différée et unique, callbacks du `MutationObserver` limités aux nœuds ajoutés.
   - Vérification : les auto-tests PiP existants (`docs/PIP_TEST_REPORT.md`, `-VoidSelfTest` PiP) doivent rester verts (risque de régression le plus important : détection des vidéos en shadow DOM et des iframes embarquées) ; ajouter un test « features » sur une page locale de 5 000 nœuds sans vidéo qui vérifie que l'observer se déconnecte ou reste sous un budget de temps.

3. **Refonte du chargement du bloqueur (sans encore changer la liste).**
   - Ajouter la nouvelle liste avant de retirer l'ancienne, mémoriser l'identifiant actif pour un démarrage sans construction de JSON, nettoyer les listes `void-*` orphelines, débouncer `reload()`.
   - Vérification : test « features » : bascule de la liste blanche pendant un chargement (la liste n'est jamais absente), le nombre d'identifiants `void-*` dans le store reste borné après 10 bascules.
   - C'est le prérequis du chantier 4 ; à faire avant.

4. **Convertisseur EasyList/EasyPrivacy → règles WebKit** (téléchargement en tâche de fond, conversion dans un `actor`, listes séparées, repli sur la liste maison).
   - Commencer par le réseau (`||domain^`, `$third-party`, `$domain=`, `@@`) et le cosmétique par domaine ; générique réduit.
   - Vérification : tests unitaires du convertisseur (jeu d'entrées EasyList → JSON attendu, rejet des règles non supportées, plafond de 150 000), test « features » : compilation réussie de la liste convertie et blocage d'une requête de test `doubleclick.net` sur une page locale ; mesure du temps de compilation et de la mémoire consignée dans le rapport `docs/selftest/features.md`.
   - Risque : temps de compilation et mémoire ; prévoir un interrupteur (Réglages) et le repli.

5. **Petites victoires WebKit, en un lot.**
   - Zoom par site persisté ; `interactionState` de l'onglet visible et des épinglés sauvé dans `session.json` (avec `SavedState.version = 2`) ; `themeColor` pour teinter la barre ou le fond de rebond ; réveil de la logique de veille sous pression mémoire (`DispatchSource.makeMemoryPressureSource`, délai réduit) ; plafond de préchargement des onglets d'arrière-plan.
   - Vérification : tests « features » : régler le zoom sur un hôte, endormir puis réveiller l'onglet, relire `pageZoom` ; tuer/relancer via `StateStore` en mémoire et retrouver `canGoBack`. Le zoom et la restauration sont facilement testables ; `themeColor` se vérifie par lecture de la valeur sur une page locale avec `<meta name="theme-color">`.

Hors top 5 mais à noter : fusion des 4 scripts en un, `Space.selectedTab` indexé, persistance de la favicon par hôte hors de `session.json`, `didReceive challenge` (auth HTTP), « Données du site » via `fetchDataRecords`, « Enregistrer en PDF » via `createPDF`.

## Points de doute déclarés
- Aucun profilage réel (Instruments) n'a été fait : les chiffres du code sont des ordres de grandeur.
- À vérifier avant de coder : `WKWebView.themeColor` (disponibilité exacte), `upgradeKnownHostsToHTTPS` (macOS 14.5 ou 15 ?), la liste exacte des `resource-type` supportés, le comportement de `ignore-previous-rules` entre listes distinctes, le temps de compilation et la mémoire d'une liste de 100 000 règles sur Apple silicon, la licence des convertisseurs AdGuard/Brave, l'absence de gestion des défis d'authentification dans `TabWebDelegate`.
