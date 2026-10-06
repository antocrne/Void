# Audit de Void — 6 octobre 2026

Branche analysée : `extensions-epinglees-sobres` (commit `5875172`).

## Méthode et limites

- **Lecture du code**, ciblée sur les zones à risque :
  - modèle (onglets, espaces, session) ;
  - délégués WebKit (Mac et iOS) ;
  - les sept scripts injectés ;
  - stockage (SQLite, JSON, trousseau) ;
  - extensions, mots de passe, téléchargements ;
  - cycle de vie de l'app et bloqueur.
- **Compilation Debug** :
  - macOS : 2 avertissements ;
  - iOS : 1 avertissement.

  Deux d'entre eux signalent un vrai bug (point 2). Le troisième (partage d'écran, méthode privée déclarée avec `@objc`) est un faux positif.
- **Recoupement** avec [`CONSEIL.md`](CONSEIL.md) et [`RAPPORT_BUGS.md`](RAPPORT_BUGS.md). Seuls les points **nouveaux** ou **encore ouverts** figurent ici. Les 23 points du rapport précédent sont corrigés, sauf la correspondance des identifiants entre sous-domaines, rappelée en divers.
- **Ce qui n'a pas été fait** : l'app n'a pas été lancée et les auto-tests n'ont pas tourné. Chaque point indique donc son niveau de certitude :
  - **Confirmé** : chemin de code sans ambiguïté, ou en-tête du SDK ;
  - **Probable** : dépend d'un comportement de WebKit à vérifier.

Gravité : 🔴 élevée · 🟠 moyenne · 🟡 faible.

**Fil rouge : le concept.** Void est « un navigateur qui s'efface » : WebKit seul, aucune dépendance, peu de chrome, tout en local. Aucune recommandation ci-dessous n'ajoute d'interface permanente ni de dépendance. Les corrections passent par :
- des réglages par défaut plus sûrs ;
- des garde-fous invisibles ;
- au pire, une feuille ou un toast au moment où il le faut.

## Verdict d'ensemble

**Le code reste sain.** Points forts :
- conventions homogènes, commentaires utiles ;
- un seul `try!`, sur des règles statiques (`AdBlockList.swift:80`), et aucun `fatalError` atteignable ;
- API privées gardées ;
- session à l'épreuve de la corruption ;
- isolation des espaces soignée.

Les deux audits précédents ont traité :
- les états anormaux (veille, plantage, fermeture) ;
- les grandes frontières : mots de passe, barre d'adresse, extensions.

**Les risques restants sont plus discrets.** Ils se trouvent à trois endroits :
1. **Les scripts injectés font confiance aux événements de la page.** Un `keydown` synthétique vaut une vraie touche (point 1).
2. **Trois réglages ou API WebKit ne font pas ce que le code suppose** :
   - méthode caméra/micro jamais appelée (point 2) ;
   - fenêtres surgissantes ouvertes par défaut sur Mac (point 3) ;
   - cookies de la session des favicons (point 4).
3. **Les stockages secondaires n'ont pas reçu le soin de la session.** Favoris, extensions et éléments masqués peuvent être perdus (point 6).

Côté projet, deux manques pèsent plus que les bugs :
- **pas de mise à jour**, ni de Void, ni des extensions ;
- **pas de tests rapides** en dehors des auto-tests graphiques.

## Synthèse

| # | Gravité | Sujet | Fichier(s) | Certitude |
|---|---|---|---|---|
| 1 | 🔴 | Une page peut lire, sans interaction, les données retenues des formulaires (e-mail, téléphone, adresse) et en planter de fausses | `formfill.js` | Confirmé |
| 2 | 🔴 | Caméra/micro : la méthode de Void n'est jamais appelée par WebKit (Mac et iOS) | `TabWebDelegate.swift` ×2 | Confirmé (compilateur + SDK) |
| 3 | 🟠 | Pas de blocage des fenêtres surgissantes sur Mac (pop-unders) | `WebViewFactory.swift` | Confirmé (SDK) |
| 4 | 🟠 | Favicons : un même pot de cookies pour tous les espaces et les fenêtres privées | `FaviconLoader.swift` | Confirmé |
| 5 | 🟠 | Extensions jamais mises à jour (gestionnaires de mots de passe compris) | `ExtensionManager.swift` | Confirmé |
| 6 | 🟠 | Favoris, extensions, éléments masqués : un fichier illisible est écrasé au prochain enregistrement | `BookmarkStore`, `ExtensionManager`, `ElementHider` | Confirmé |
| 7 | 🟠 | Appareils du réseau local en HTTPS auto-signé (routeur, NAS) inaccessibles | `TabWebDelegate.swift` | Confirmé |
| 8 | 🟡 | « Effacer l'historique » laisse les pages lisibles dans le fichier SQLite | `HistoryStore.swift` | Probable |
| 9 | 🟡 | Scripts injectés : observateurs permanents dans chaque cadre, mises en page forcées | `core.js`, `autofill.js` | Confirmé (lecture) ; coût à mesurer |
| 10 | 🟡 | Barre d'adresse : « node.js », « readme.md » ouverts comme des sites ; « nas:5000 » cherché | `URLResolver.swift` | Confirmé |
| 11 | 🟡 | ⌘⇧T rouvre l'adresse sans l'historique de l'onglet | `BrowserModel.swift` | Confirmé |
| 12 | 🟡 | Zoom ni mémorisé par site, ni gardé après une mise en veille | `BrowserModel+Actions.swift` | Confirmé |
| 13 | 🟡 | Divers (double chargement, lecteur sans bloqueur, clics synthétiques…) | plusieurs | Confirmé |
| A | — | Architecture, tests, distribution, accessibilité | — | — |

**Ordre conseillé** :
1. Points 1, 2, 3 et 4 : quelques lignes chacun, ils ferment des fuites réelles.
2. Point 6 : perte de données.
3. Points 5 et 7.
4. Le reste.
5. En parallèle : une cible de tests rapides et « avertissements = erreurs » (§ A), pour que le point 2 ne puisse pas revenir.

---

## 🔴 1. Remplissage des formulaires : lecture silencieuse et empoisonnement

**Où** : `Void/Resources/Scripts/formfill.js:108-125`, `:43-45`, actif par défaut (`AppSettings.formAutofillEnabled = true`).

**Le principe.** `formfill.js` tourne dans le monde isolé, mais il écoute des événements du DOM, que la page partage et peut fabriquer. Aucun écouteur ne vérifie `event.isTrusted`, sauf celui d'`activity.js`.

**Lecture sans interaction.** Une page, ou un cadre publicitaire (le script est injecté dans tous les cadres), procède ainsi :
1. Elle crée un `<input name="email">` invisible (opacité 0 ou hors écran : `keyFor` ne vérifie pas la visibilité).
2. Elle appelle `input.focus()`. `focusin` part, Void envoie les valeurs retenues pour `email` et `render()` les affiche.
3. Elle envoie `input.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowDown'}))`, puis `{key: 'Enter'}`. L'écouteur de la ligne 118 accepte ces touches et `pick()` écrit la valeur dans le champ.
4. Elle lit `input.value`. En recommençant avec ArrowDown ×2, ×3…, elle obtient les 6 premières valeurs.
5. Elle répète l'opération avec `tel`, `name`, `given-name`, `family-name`, `street-address`, `postal-code`, `address-level2`, `organization`…

Résultat : l'adresse e-mail, le téléphone, le nom et l'adresse postale de l'utilisateur sont lus en quelques millisecondes, sans clic. Dans le cadre principal, c'est certain. Dans un cadre tiers, cela dépend des règles de WebKit sur le focus.

**Empoisonnement.** Un `keydown` Entrée synthétique sur un champ (ligne 43) déclenche `capture()`. La page peut donc enregistrer `email = attaquant@exemple.com` en tête des suggestions, **pour tous les sites**. L'utilisateur le choisira plus tard dans un formulaire d'inscription ou de commande, et ses reçus partiront ailleurs.

**Correction** (sans changer l'interface) :
```js
// formfill.js — seules les touches et clics réels de l'utilisateur comptent
document.addEventListener('keydown', (e) => {
  if (!e.isTrusted || !box || e.target !== current) return;
  …
}, true);
document.addEventListener('keydown', (e) => {          // capture à l'Entrée (l. 43)
  if (e.isTrusted && e.key === 'Enter' && …) capture(e.target.form);
}, true);
document.addEventListener('click', (e) => { if (!e.isTrusted) return; … }, true);
```
- Ne proposer la liste qu'après une **interaction réelle** avec le champ : un `pointerdown` ou un `keydown` de confiance dont la cible est le champ. Un `focus()` scripté ne suffit plus.
- Ignorer les champs invisibles : réutiliser le `visible()` d'`autofill.js`, qui teste taille et `visibility`, et ajouter l'opacité.
- Option plus sobre : ne rien proposer dans un cadre d'une autre origine que la page.

**Test à ajouter** (section `formulaires`) : sur une page locale, un script de page fait `focus()` puis ArrowDown/Entrée synthétiques. Attendu : le champ reste vide et aucune valeur n'est retenue.

---

## 🔴 2. Caméra et micro : la méthode de Void n'est jamais appelée

**Où** : `Void/Web/TabWebDelegate.swift:317` et `VoidiOS/Web/TabWebDelegate.swift:111`. Le compilateur le signale :

> instance method 'webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:)' nearly matches optional requirement 'webView(_:decideMediaCapturePermissionsFor:initiatedBy:type:)'

**Cause.** L'en-tête du SDK (`WKUIDelegate.h:165`) déclare la forme asynchrone Swift sous le nom `webView(_:decideMediaCapturePermissionsFor:initiatedBy:type:)`. La méthode de Void porte un autre nom. Elle n'est donc ni exposée à Objective-C (vérifié dans les métadonnées du binaire) ni appelée : **tout `MediaPermission` est du code mort.**

**Ce que fait WebKit à la place**, vérifié avec ses périphériques fictifs :
- avec l'invite du mode fictif activée, il **affiche sa propre question** : c'est le cas réel ;
- sans cette invite, il **accorde l'accès d'office**.

L'ancien auto-test obtenait `NotAllowedError` pour une autre raison : macOS (TCC) refuse la caméra à un processus lancé depuis un terminal, et WebKit refuse avant même de consulter le délégué.

**Conséquences** :
- les protections de `MediaPermission` ne s'appliquent pas :
  - une question par site et par session ;
  - refus retenu une minute contre les boucles ;
  - demande refusée pour un onglet non affiché ;
  - message quand macOS refuse l'accès ;
  - clé distincte par fenêtre privée ;
- l'auto-test `reunion` compte sur `MediaPermission.decide` pour répondre `.deny` sans ouvrir la caméra. Ce chemin n'est jamais emprunté : ce que le test vérifie vraiment est à revoir ;
- le libellé du README (« Réunion en fenêtre flottante… vérifié ») repose en partie sur ce chemin.

**Correction** (Mac et iOS) :
```swift
func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
             initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
    … // corps inchangé
}
```
Puis relancer `reunion` et `visio`, et faire un essai réel sur Meet ou Jitsi.

**Pour que cela ne revienne pas** : passer `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, au moins en Release (voir § A). Deux des trois avertissements du projet étaient ce bug. Le troisième (`_webView:requestDisplayCapturePermissionForOrigin:…`, méthode privée appelée par son sélecteur `@objc`) est un faux positif : le faire taire en renommant la méthode Swift, par exemple `webViewRequestDisplayCapture(…)`, en gardant le même `@objc(…)`.

---

## 🟠 3. Pas de blocage des fenêtres surgissantes sur Mac

**Où** : `Void/Web/WebViewFactory.swift:68-70` (préférences), `TabWebDelegate.swift:223-232` (`createWebViewWith`).

**Constat.** `WKPreferences.javaScriptCanOpenWindowsAutomatically` vaut **YES sur macOS** et NO sur iOS : l'en-tête `WKPreferences.h:45` le dit. Void ne le change pas, et `createWebViewWith` crée un onglet pour toute demande. Une page peut donc ouvrir des onglets sans clic, par exemple :
- dans un minuteur ;
- au chargement ;
- en pop-under sur un site de streaming ou de téléchargement.

C'est l'un des désagréments les plus visibles du web, et le contraire d'un navigateur qui s'efface.

**Correction** : une ligne.
```swift
prefs.javaScriptCanOpenWindowsAutomatically = false   // comme Safari : seulement en réponse à un clic
```
WebKit continue d'accepter `window.open` dans un geste de l'utilisateur : connexions OAuth, « Partager ». Il faut le vérifier sur une connexion Google ou Apple en fenêtre surgissante.

Option, dans l'esprit de Void : un toast discret « Fenêtre bloquée — ouvrir ». Il demande de savoir qu'un `window.open` a été refusé ; sans API publique pour cela, le blocage silencieux suffit.

---

## 🟠 4. Favicons : un pot de cookies commun à tous les espaces et aux fenêtres privées

**Où** : `Void/Web/FaviconLoader.swift:7`.

**Constat.** Les icônes sont téléchargées hors de WebKit, par `URLSession(configuration: .ephemeral)`. Une session éphémère n'écrit rien sur le disque, mais elle **garde en mémoire ses cookies et son cache pendant toute la vie de l'app**, et elle est partagée par tous les onglets :
- onglets de tous les espaces ;
- onglets des fenêtres privées (`load(for:)` est appelé pour tout onglet).

**Exemple.** Un site, ou son CDN, pose un cookie sur `/favicon.ico` depuis l'espace « Personnel ». Le même cookie est renvoyé à la visite du site depuis « Travail » ou depuis une fenêtre privée. Le serveur peut ainsi relier trois contextes que Void promet de séparer (« isolation des cookies vérifiée »). Le Conseil l'avait noté (« favicons sans cookies ») ; ce n'est pas fait.

**Correction** :
```swift
nonisolated private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCache = nil
    return URLSession(configuration: config)
}()
```
C'est ce que fait déjà `QuickConverter` (`request.httpShouldHandleCookies = false`). Option plus stricte : dans une fenêtre privée, se contenter du cache mémoire et ne rien télécharger.

---

## 🟠 5. Les extensions ne sont jamais mises à jour

**Où** : `Void/Features/Extensions/ExtensionManager.swift`. Il n'existe aucune vérification de version : une extension reste dans la version installée tant que l'utilisateur ne la réinstalle pas.

**Pourquoi c'est sérieux.** Le cas typique est un gestionnaire de mots de passe (Proton Pass, Bitwarden, 1Password). Il a accès à tous les sites et reçoit régulièrement des correctifs de sécurité. Chrome le met à jour en quelques heures. Dans Void, il vieillit en silence, et les incompatibilités avec les serveurs du gestionnaire finissent par le casser.

**Correction, sans dépendance ni interface** :
- **Quand** : au lancement, au plus une fois par jour, pour chaque extension qui a un `chromeID`.
- **Comment** : interroger `https://clients2.google.com/service/update2/crx?…&x=id%3D<id>%26uc`. La réponse XML donne la version et l'URL du paquet. C'est déjà le service qu'utilise `ChromeExtensions.downloadFromWebStore`.
- **Si la version est plus récente** : appeler le chemin existant `add(_:chromeID:)`. Il gère déjà les données conservées, le remplacement de la copie et la **nouvelle demande d'autorisations** quand la mise à jour en veut plus. C'est le comportement de Chrome.
- **Ce que l'utilisateur voit** : un toast « Proton Pass mis à jour ». Dans Réglages → Extensions, une ligne « Mettre à jour automatiquement », active par défaut.
- **Hors périmètre** : les extensions venues d'un fichier ou d'un dossier, sans identifiant, ne sont pas concernées.

---

## 🟠 6. Favoris, extensions, éléments masqués : un fichier illisible est écrasé

**Où** :
- `BookmarkStore.swift:19-24` et `:69-71` ;
- `ExtensionManager.swift:95-105` (`extensions.json`) ;
- `ElementHider.swift:16` et `:66`.

**Constat.** La session a été rendue « incassable » : lecture champ par champ, fichier abîmé mis de côté, copie de secours. Les trois autres fichiers JSON ont gardé le schéma d'origine :
1. le décodage est tout ou rien ;
2. en cas d'échec, la liste en mémoire est vide ;
3. **au premier enregistrement, ⌘D ou masquage d'un élément, le fichier est réécrit vide.**

Un seul favori au format inattendu suffit : une URL que `URL` refuse, une écriture interrompue par un plantage du disque, une version future de Void qui ajoute un champ obligatoire. Les cas les plus probables :
- **favoris** : ceux importés de Chrome ou d'Arc, souvent des centaines, perdus sans retour ;
- **`extensions.json`** : toutes les extensions disparaissent de Void, leurs dossiers restent orphelins dans `Extensions/` et l'épinglage est perdu.

**Correction** : factoriser ce que fait `StateStore`.
```swift
/// Lit un tableau JSON élément par élément ; un fichier illisible est mis de côté, jamais écrasé.
enum TolerantFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> [T]? { … Lossy<T> … }
}
```
- `Lossy` existe déjà dans `StateStore.swift` : le rendre interne au module.
- Pour les trois fichiers : décodage par élément, renommage `*.corrupt-<date>.json` en cas d'échec, et pas d'écriture tant que la lecture a échoué.
- Pour `extensions.json`, on peut aussi reconstruire la liste à partir des dossiers de `Extensions/`, qui contiennent chacun un `manifest.json`.

---

## 🟠 7. Routeur, NAS : impossible d'ouvrir un appareil en HTTPS auto-signé

**Où** : `Void/Web/TabWebDelegate.swift:165-174`.

**Constat.** Le délégué d'authentification ne traite que les méthodes à mot de passe. Pour `NSURLAuthenticationMethodServerTrust`, il renvoie `.performDefaultHandling` : un certificat auto-signé fait échouer la page, avec seulement le message d'erreur de `loadError`. Or :
- les box, NAS (Synology, QNAP), imprimantes, Home Assistant ou Proxmox servent presque tous du HTTPS auto-signé ;
- le README cite justement « routeurs, NAS, intranets » pour l'authentification HTTP.

Sur ces appareils, Void ne peut rien ouvrir. Safari et Chrome proposent « Visiter ce site web quand même ».

**Correction**, pour ne pas ouvrir de brèche sur Internet :
- **Où proposer** : seulement pour les hôtes locaux. Cela couvre les adresses privées (`10/8`, `172.16/12`, `192.168/16`, `fe80::/10`, `fc00::/7`), `.local`, `.lan`, `.home.arpa` et les noms sans point.
- **Ce que l'utilisateur voit** : la page d'erreur ou une feuille propose « Continuer vers 192.168.1.1 ».
- **Ce qui est retenu** : l'exception porte sur l'empreinte du certificat et l'hôte (`SecTrustCopyCertificateChain`), pour la session ou de façon durable selon le choix.
- **Ensuite** : répondre `.useCredential` avec `URLCredential(trust:)` uniquement si l'empreinte correspond. Un changement de certificat redemande.
- **Le cadenas** est barré tant que l'exception est utilisée.
- **Partout ailleurs** : aucune exception possible. C'est cohérent avec la sobriété de Void.

---

## 🟡 8. « Effacer l'historique » laisse les pages lisibles sur le disque

**Où** : `Void/Features/Library/HistoryStore.swift:92-94`, `SQLiteDB.swift:18-22`.

**Constat.** `DELETE FROM history` marque les pages libres, mais il ne réécrit pas leur contenu. En mode WAL, les anciennes versions restent en plus dans `history.sqlite-wal` jusqu'au prochain *checkpoint*. Après « Effacer l'historique », les URL et titres restent probablement lisibles avec un éditeur hexadécimal ou un outil de récupération SQLite. C'est le cas typique : un ordinateur prêté, ou une sauvegarde Time Machine.

**Correction** :
```swift
// SQLiteDB.init, pour les bases de Void
execute("PRAGMA secure_delete=ON")        // le contenu supprimé est mis à zéro
// HistoryStore.clear()
db?.execute("DELETE FROM history")
db?.execute("PRAGMA wal_checkpoint(TRUNCATE)")
db?.execute("VACUUM")
```
Le coût de `secure_delete` est négligeable pour une base de cette taille. Même chose après `delete(_:)` et après l'élagage quotidien.

---

## 🟡 9. Scripts injectés : un coût permanent dans chaque cadre

**Où** :
- `core.js:48-57` : `MutationObserver` sur tout le document, dans **tous** les cadres, pendant toute la vie de la page ;
- `autofill.js:83-91` : observateur tant qu'aucun formulaire de connexion n'est vu, c'est-à-dire pour toujours sur la plupart des pages.

**Constat** :
- **`core.js`** : chaque élément ajouté qui a des enfants déclenche `querySelectorAll('iframe')` sur son sous-arbre. Sur les pages qui reconstruisent sans cesse leur DOM (X, Slack, Gmail, flux infinis), cela s'additionne à chaque lot de mutations, et dans chaque cadre publicitaire.
- **`autofill.js`** : `check()` lance `querySelectorAll('input[type=password]')`, puis `getBoundingClientRect()` et `getComputedStyle()`. Ces appels **forcent une mise en page** après chaque pause de 400 ms des mutations, là encore dans chaque cadre.
- Ces scripts n'ont jamais été mesurés (angle mort du Conseil : « mesure de performance sur un Mac modeste »).

**Pistes**, sans perte de fonction :
- **`core.js`** :
  - ne regarder que `node.tagName === 'IFRAME'`, et `node.getElementsByTagName('iframe')` (collection vivante, bien moins chère) seulement si le nœud est grand ;
  - ne pas installer l'observateur dans les cadres sans origine de lecteur connu.
- **`autofill.js`** :
  - tester d'abord l'existence d'un `input[type=password]`, sans visibilité, et ne mesurer la mise en page qu'ensuite ;
  - arrêter d'observer après 30 s sans formulaire, puis reprendre au premier `focusin` sur un champ.
- **Mesurer** : profil Instruments (*WebKit* et *Time Profiler*), 5 minutes sur X ou Gmail avec et sans les scripts, sur un Mac M1 8 Go.

---

## 🟡 10. Barre d'adresse : quelques mauvaises devinettes

**Où** : `Void/Browser/URLResolver.swift:24-27`.

**Constat** :
- **Faux sites.** Toute suite de lettres après un point passe pour un domaine de premier niveau. « node.js », « next.js », « vue.js » ou « fichier.pdf » ouvrent `https://node.js`… puis une erreur. « readme.md » ouvre même un vrai domaine (`.md` est la Moldavie).
- **Recherches au lieu d'appareils.** Un nom sans point est toujours cherché : « nas:5000 », « routeur », « intranet/wiki ».

**Correction**, dans l'esprit de Void, sans liste ni interface :
- Quand une adresse **tapée sans schéma** échoue avec `NSURLErrorCannotFindHost`, lancer la recherche à la place, ou proposer « Rechercher « node.js » » sur la page d'erreur. C'est ce que fait Chrome.
- Pour `nom:port` et `nom/chemin` sans point, tenter `http://nom…` : un `:port` ou un `/` montre que l'utilisateur vise une adresse.

---

## 🟡 11. ⌘⇧T rouvre l'adresse, pas l'onglet

**Où** : `BrowserModel.swift:94`, `:245`, `:316-320`.

**Constat.** `closedTabs` garde l'URL seule. Un onglet fermé par erreur revient sans son historique : « Précédent » est grisé et la position dans la page est perdue. Or Void sait déjà sauver tout cela pour la mise en veille, avec `interactionState` et `pendingScroll`.

**Correction** :
- garder `(url, spaceID, interactionState, title, favicon)` au moment de la fermeture, quand la vue web existe encore ;
- au ⌘⇧T, recréer l'onglet avec cet état. `Tab.savedInteractionState` existe ; il suffit d'un initialiseur qui l'accepte.
- La limite de 30 entrées suffit : un `interactionState` pèse quelques kilo-octets.

---

## 🟡 12. Zoom : ni mémorisé, ni conservé

**Où** : `BrowserModel+Actions.swift:21-24`.

**Constat.** `pageZoom` vit dans la vue web :
- il est perdu à chaque mise en veille automatique ou manuelle, et au relancement ;
- il n'est pas retenu par site. C'était un « suivant naturel » du Conseil.

**Correction** :
- un dictionnaire `hôte → zoom` dans `AppSettings`, écrit par ⌘+ ⌘− ⌘0 (⌘0 retire l'entrée) ;
- appliqué dans `didCommit` quand l'hôte change ;
- jamais écrit depuis une fenêtre privée.

---

## 🟡 13. Divers

- **Double chargement d'un onglet endormi** (`Tab.swift:166-172`). `load(_:)` fixe `url`, puis `ensureWebView()` lance déjà le chargement (via `ContentRules.whenReady`), puis `load` le relance aussitôt. Conséquences : deux requêtes, la première annulée, et la seconde part sans attendre les règles du bloqueur. Correction : ne pas appeler `wv.load` quand `ensureWebView` vient de créer la vue avec cette URL.
- **Bloqueur au lancement** (`ContentRules.swift:34`). Les pages sont libérées au bout de 0,5 s même si la liste n'est pas compilée : après une mise à jour d'`AdBlockList.version`, la compilation part de zéro. Le compromis est assumé, mais il mérite une ligne dans le README, ou un délai plus long quand la liste n'est pas en cache.
- **Mode lecture** (`ReaderMode.swift:119-121`). La vue de lecture n'a pas les listes du bloqueur : les pixels de suivi présents dans les images de l'article se chargent. Correction : `config.userContentController.add(adBlockList)`.
- **Clics synthétiques ailleurs** :
  - **`autofill.js:48-53`** : une page peut déclencher « Enregistrer le mot de passe ? » avec des valeurs de son choix (faible, l'utilisateur doit accepter) ;
  - **`webstore.js:43`** : le bouton « Ajouter à Void » accepte un clic de script. Risque faible, car limité à la page du Store et suivi de la confirmation d'installation.

  Dans les deux cas, ajouter `if (!e.isTrusted) return;`.
- **Identifiants entre sous-domaines** (`KeychainStore.swift:96-101`, point 22 resté ouvert). Un identifiant de `exemple.com` est proposé sur `n-importe-quoi.exemple.com`, y compris sur des sous-domaines où des utilisateurs publient leur propre contenu. Touch ID et le choix explicite limitent le risque. Une courte liste de suffixes « hébergeurs » (`github.io`, `pages.dev`, `vercel.app`, `netlify.app`, `blogspot.com`…) éviterait l'essentiel sans embarquer la liste complète des suffixes publics.
- **Liste des téléchargements perdue au relancement** (`DownloadManager.items` en mémoire seulement). Elle est vide à chaque lancement alors que la Bibliothèque a une section Téléchargements. Il faut soit la conserver (JSON, sans les privés), soit le dire.
- **Historique** : les URL sont gardées avec leurs paramètres (`?token=`, `?code=` de connexion, liens de réinitialisation) et ressortent dans les suggestions. On peut retirer les paramètres connus comme secrets, ou ne pas suggérer les URL qui en contiennent.

---

## A. Architecture, tests, distribution, accessibilité

### Avertissements = erreurs
Le projet compile avec **trois avertissements seulement** : deux pour le bug du point 2 (Mac et iOS) et un faux positif. C'est une base idéale pour une règle « zéro avertissement ». À faire :
- `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` en Release ;
- `GCC_TREAT_WARNINGS_AS_ERRORS` pour le reste.

Le point 2 aurait été bloqué à la compilation.

### Tests rapides, sans dépendance
**Constat.** Les auto-tests sont précieux mais lourds :
- Debug seulement, interface graphique, écran déverrouillé ;
- un fichier de 2 600 lignes ;
- pas d'intégration continue.

**Proposition.** Une petite cible **XCTest** (système, aucune dépendance) pour la logique pure :

| Sujet | Ce qu'on teste |
|---|---|
| Barre d'adresse | `URLResolver` |
| Conversions | `QuickConverter` |
| Session | `SavedState` et sa tolérance aux fichiers abîmés |
| Liens externes | `ExternalURLPolicy` |
| Téléchargements | `DownloadManager.sanitizedFilename` et `uniqueDestination` |
| Extensions | `ExtensionGrant.covers` |
| Mots de passe | `KeychainStore.logins(matching:)` |
| Formulaires | `keyFor` de `formfill.js`, via `JSContext` |

Ces tests tournent en quelques secondes, en ligne de commande. Ils peuvent passer sur chaque PR dans une action GitHub sur un runner macOS (gratuit pour un dépôt public).

### Duplication Mac / iOS
Les deux `TabWebDelegate` partagent l'essentiel de leurs décisions (schémas externes, ⌘-clic, téléchargements, authentification, caméra) : le bug du point 2 est **copié à l'identique**. On peut extraire un `NavigationPolicy` commun, aux décisions pures et testables, et ne laisser à chaque plateforme que l'affichage (`NSAlert` ou `Dialogs`). Même remarque, à moindre degré, pour `SettingsView`, `LibraryView`, `PageView` et `BrowserWindows`.

### Concurrence
**Constat.**
- Le projet est en Swift 5 et compte 47 `MainActor.assumeIsolated`. Ils sont justes aujourd'hui : les rappels KVO de WebKit, `ScriptMessageRouter` et les notifications sur `.main` arrivent bien sur le fil principal.
- Mais une erreur future se paierait d'un **plantage à l'exécution**, pas d'une erreur de compilation.

**Proposition.**
- Passer en mode Swift 6 progressivement, fichier par fichier, en commençant par `Features/Library`. Pas urgent.
- Le Conseil avait écarté un « refactor diffus » : c'est compatible si chaque fichier est un commit.

### Gros fichiers
- `SettingsView.swift` (811 lignes, Mac) : un fichier par section.
- `ExtensionManager.swift` (836 lignes) : séparer installation, cycle de vie (service worker) et délégué.
- `FeatureSelfTest.swift` (2 598 lignes) : un fichier par section `-VoidSelfTestOnly`.

### Distribution et mises à jour
- **Signature.** La signature ad hoc, sans notarisation, pose trois problèmes :
  - sur un autre Mac, Gatekeeper bloque l'app (« impossible de vérifier le développeur ») ;
  - le trousseau redemande l'accès après chaque mise à jour ;
  - le *data protection keychain* n'est pas disponible.

  Avec un compte développeur, ajouter à `make-dmg.sh` : signature Developer ID, `xcrun notarytool submit --wait`, puis `xcrun stapler staple`.
- **Mises à jour de Void.** Il n'y en a aucune. Dans l'esprit de Void, sans Sparkle ni dépendance, voici ce qui suffit :
  - une vérification hebdomadaire, désactivable, d'un petit fichier `latest.json`, ou de l'API GitHub Releases ;
  - si une version plus récente existe : un toast « Void 0.2 est disponible » qui ouvre la page de téléchargement ;
  - aucune installation automatique.

### Accessibilité
**Constat.** Le code compte 33 modificateurs d'accessibilité pour ≈ 20 000 lignes. Beaucoup de boutons sont de simples icônes :
- 🧩 et les extensions épinglées ;
- l'anneau des téléchargements, l'œil privé ;
- les icônes d'espaces, les onglets épinglés en grille.

`.help()` donne une bulle d'aide, pas un nom VoiceOver. Sans libellé, VoiceOver lit le nom du symbole (« puzzlepiece extension ») ou rien du tout.

**Proposition.**
- Passer une heure avec l'*Accessibility Inspector* sur la barre latérale, la barre du haut, la barre de commande et les Réglages.
- Ajouter `.accessibilityLabel` aux boutons-icônes.
- Une interface qui s'efface à l'œil doit rester audible : c'est invisible et conforme au concept.

### Dépôt
- `Void.xcodeproj/xcshareddata/` (schémas partagés) n'est **pas suivi** par git. Sur un clone neuf, ou en intégration continue, `xcodebuild -scheme Void` dépend de schémas générés automatiquement. Il faut le committer.
- **README en retard sur le code** :
  - il annonce « ~13 600 lignes de Swift » ; le dépôt en compte ≈ 19 800 avec iOS et les auto-tests ;
  - la section « Réunion » s'appuie en partie sur le point 2.

---

## Ce qui va bien (à garder)

- **Légèreté réelle** :
  - une seule vue web au lancement ;
  - mise en veille avec position et historique ;
  - réaction à la pression mémoire ;
  - règles compilées et mises en cache.
- **Isolation** :
  - scripts dans un monde nommé ;
  - un magasin par espace, retiré du disque même quand WebKit résiste ;
  - fenêtre privée à magasin propre, détruit à la fermeture.
- **Défense en profondeur** :
  - mots de passe verrouillés sur l'origine du cadre, revérifiée en JS ;
  - symlinks refusés dans les extensions, écritures atomiques ;
  - schémas réseau refusés, quarantaine garantie ;
  - un seul Void grâce à un verrou de fichier.
- **Robustesse** :
  - session tolérante, avec copie de secours ;
  - plantage de page sans boucle ;
  - alertes d'onglets cachés sans blocage ;
  - `beforeunload` respecté.
- **Code lisible** : les commentaires expliquent *pourquoi* (comportements de WebKit, cas vécus), ce qui a rendu cet audit rapide.

## Suivi

Branche `audit-octobre`, partie de `main` @ `7c52049`. Chaque point a d'abord été reproduit par un nouvel auto-test sur le code d'origine (6 ❌), puis corrigé.

| Commit | Point | Avant → après |
|---|---|---|
| `718febd` | 1 — formulaires (et `autofill.js`, `webstore.js`) | valeurs lues et plantées par la page → rien lu, rien planté ; le clic, ↓, Entrée de l'utilisateur fonctionne toujours |
| `4689187` | 2 — caméra et micro (Mac et iOS) | 0 demande reçue par Void → la demande passe par `MediaPermission` ; plus aucun avertissement de compilation |
| `ac2c8ce` | 3 — fenêtres surgissantes | 2 onglets ouverts sans clic → 0 ; un geste ouvre toujours son onglet |
| `403cece` | 4 — favicons | cookie renvoyé → jamais renvoyé |

**Vérification** :
- sections `formulaires`, `visio`, `fenetres-surgissantes`, `favicons`, et les sections voisines `mots-de-passe`, `nouvel-onglet`, `onglets`, `stabilite`, `corrections`, `adresse`, `telechargements`, `extensions`, `notes` : **92 ✅ / 0 ❌** ;
- cibles Mac et iOS compilées sans avertissement.

**Reste à faire à la main** : un vrai appel (Jitsi, Meet), qui doit afficher la question de Void (« Autoriser « … » à utiliser la caméra et le micro ? »), et une connexion OAuth en fenêtre (« Se connecter avec Google »).

## Suggestion de lot de corrections

Une branche `audit-octobre`, un commit par point, comme pour `nuit-conseil` :

| Commit | Points | Taille estimée | Vérification |
|---|---|---|---|
| 1 | 1 — `isTrusted` et interaction réelle dans `formfill.js` (et 13 : `autofill.js`, `webstore.js`) | ~20 lignes JS | nouvel auto-test `formulaires` |
| 2 | 2 — renommage caméra/micro, Mac et iOS | 2 lignes | `reunion`, `visio` + essai Jitsi |
| 3 | 3 — `javaScriptCanOpenWindowsAutomatically = false` | 1 ligne | auto-test : `window.open` sans geste → pas d'onglet ; avec clic → onglet |
| 4 | 4 — session des favicons sans cookies ni cache | 6 lignes | auto-test : cookie posé sur `/favicon.ico` d'un serveur local, absent de la requête suivante |
| 5 | 6 — lecture tolérante des trois fichiers JSON | ~40 lignes | auto-test sur un dossier temporaire, comme la session |
| 6 | A — avertissements = erreurs, schémas partagés suivis | réglages | compilation |
| 7 | 8 — `secure_delete` et `VACUUM` | 4 lignes | auto-test `historique` |
| ensuite | 5, 7, 9–12 | — | à planifier |
