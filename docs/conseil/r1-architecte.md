# Conseil des agents — Rapport de l'Architecte (relecture de code sénior)

Périmètre : `Void/` en entier (8 051 lignes de Swift, 575 lignes de JS injecté), branche `nuit-conseil` @ 40cb9b0. Lecture seule, rien n'a été modifié.
Légende : **[V]** = vérifié en lisant le code (le scénario découle directement des lignes citées) · **[S]** = supposition sur le comportement de WebKit/AppKit, à confirmer par un test.
Gravité : 🔴 haute · 🟠 moyenne · 🟡 basse.

## 0. Impression générale

Le code est propre, bien commenté et cohérent. Les bases sont saines :
- pas de cycle de rétention évident avec WKWebView : `Tab → webView` fort, `webView.tab` faible, `TabWebDelegate.tab` faible, fermetures KVO en `[weak self]`, `whenReady { [weak wv] }` ;
- un seul `WKUserContentController` partagé, avec un routeur singleton : pas de fuite de message handler par onglet ;
- des scripts dans un monde isolé et des SPI protégées par `responds(to:)`.

Les faiblesses tiennent surtout à trois choses :
- **la robustesse aux états anormaux** : session illisible, crash du processus web, cadres média périmés, PiP pendant la mise en veille ;
- **quelques trous de sécurité ou de confidentialité** : remplissage des mots de passe entre origines, quarantaine des téléchargements, copies temporaires de l'import ;
- **tout ce qui s'exécute sur le thread principal** : SQLite, trousseau, import.

Côté architecture, le point faible est le recours systématique aux singletons, avec un repli silencieux sur `BrowserModel.shared`.

Le README indique « ~5 700 lignes de Swift » alors qu'il y en a 8 051 : la documentation a pris du retard **[V]**.

---

## 1. Bugs réels (modèle, cycle de vie, concurrence)

### 1.1 🔴 Session illisible : perte totale des espaces, des épinglés **et des connexions** — [V] + [S]
- `Browser/StateStore.swift:37-40` : `try? JSONDecoder().decode` renvoie `nil` au moindre écart.
- `Browser/BrowserModel.swift:121-126` : Void repart alors sur « Personnel / Travail » avec de **nouveaux UUID**.
- `BrowserModel.swift:437-447` : la première sauvegarde, une seconde plus tard, écrase le fichier d'origine.
- **Scénario** : `session.json` tronqué (disque plein, crash pendant l'écriture hors `.atomic`, modification manuelle) ou, bien plus probable, **une future version qui ajoute un champ non optionnel** à `SavedTab`/`SavedSpace` (`version = 1` n'est jamais lu).
- **Conséquence** : toutes les données des sites sont indexées par l'UUID de l'espace (`WKWebsiteDataStore(forIdentifier: id)`, `Space.swift:40`). Avec de nouveaux UUID, l'utilisateur est **déconnecté de tout**, et les anciens magasins restent orphelins sur le disque. [S] pour le détail du stockage WebKit, [V] pour la logique.
- **Correctif** :
  - en cas d'échec de décodage, renommer le fichier en `session.corrupt-<date>.json` et ne jamais l'écraser ;
  - écrire un `init(from:)` tolérant (`decodeIfPresent` pour tout ce qui est ajouté) et tenir compte de `version` ;
  - récupérer les espaces orphelins avec `WKWebsiteDataStore.fetchAllDataStoreIdentifiers` (macOS 14+) et recréer un espace « Récupéré » par identifiant inconnu ;
  - rendre le chemin injectable pour l'auto-test.
- **Effort** : 2 à 3 h.

### 1.2 🟠 ⌘W sur un onglet épinglé en PiP ou en lecteur flottant : ni veille ni sortie propre — [V]
- `BrowserModel.swift:191-195` lance `Task { await PiPController.shared.exit(tab) }` (asynchrone), puis appelle **immédiatement** `tab.sleep()`.
- Or `Tab.swift:136` sort sans rien faire tant que `isInPiP || isInFloatingPlayer` : `isInPiP` ne passe à `false` qu'après environ 300 ms (`PiPController.swift:152-153`).
- **Scénario** : l'onglet est désélectionné et le toast annonce « Onglet épinglé mis en veille », alors que la vue web reste vivante (KVO, délégué, média). Même chose avec le lecteur flottant : `FloatingPlayer` n'est jamais fermé dans cette branche.
- **Correctif** : `Task { await exit(tab); tab.sleep() }`, fermer `FloatingPlayer` d'abord, afficher le toast après.
- **Effort** : 30 min.

### 1.3 🟠 Fermeture (non épinglée) ou `tearDown` d'un onglet en PiP : `sleep()` ignoré — [V]
- `BrowserModel.swift:199,208` et `:401-402` : `forceExit` est « best effort » et ne remet pas `tab.isInPiP` à `false`. Le `tab.sleep()` qui suit sort donc sans rien faire (`Tab.swift:136`).
- En pratique, l'onglet est retiré de `space.tabs` et la vue web sera libérée avec le `Tab`, mais sans `stopLoading` ni délégués remis à nil. Pour une **fenêtre privée**, `tearDown` suppose que tout a été endormi.
- **Correctif** : ajouter `sleep(force: Bool)` (ou `tab.isInPiP = false; tab.isInFloatingPlayer = false`) avant `sleep()` dans les chemins de fermeture.
- **Effort** : 20 min.

### 1.4 🟠 Cadres média périmés : onglet « en lecture » pour toujours — [V]
- `PiPController.swift:40-48` : `mediaFrames` est indexé par URL de cadre + hôte, et ne se vide qu'au `didCommit` du cadre principal (`TabWebDelegate.swift:79`, `resetFrames`).
- `media.js` n'envoie rien sur `pagehide` ou `unload` (vérifié par grep).
- **Scénario** : une iframe vidéo (pub autoplay, embed YouTube) en lecture est retirée du DOM, ou navigue vers une autre URL (nouvelle clé), sur une page SPA sans commit du cadre principal. L'entrée `playing: true` reste. Conséquences :
  - `isPlayingVideo` reste vrai ;
  - `keepAliveTabs` garde la vue web attachée à la fenêtre (`BrowserModel.swift:139-141`) ;
  - l'onglet n'est jamais mis en veille (`Tab.swift:186`) ;
  - chaque changement d'onglet relance une tentative d'auto-PiP (`PiPController.swift:181-186`) ;
  - l'icône « son » s'affiche à tort.
- **Correctif** :
  - `media.js` : `addEventListener('pagehide', () => post({hasVideo:false, playing:false, audible:false, inPiP:false}))` ;
  - côté Swift : horodater chaque entrée et purger celles qui ne se sont pas manifestées depuis plus de 60 s lors de `sleepInactiveTabs`.
- **Effort** : 1 h avec un auto-test (page avec iframe vidéo, puis `iframe.remove()`, puis vérifier `isPlayingVideo == false`).

### 1.5 🟠 Crash du processus web : rechargement inconditionnel, possible boucle — [V] + [S]
- `TabWebDelegate.swift:108-110` : `webView.reload()` sans condition.
- **Scénario 1** : une page qui fait planter WebContent (OOM, bug WebKit) recharge → replante → recharge, et brûle CPU et mémoire indéfiniment.
- **Scénario 2** : sous pression mémoire, macOS tue les processus des onglets en arrière-plan. Tous rechargent **en même temps**, ce qui augmente encore la pression. [S] sur l'ampleur.
- **Correctif** :
  - onglet non visible : le mettre en veille (`savedInteractionState = webView.interactionState; sleep()`), il se rechargera au clic ;
  - onglet visible : recharger au plus une fois toutes les 30 s, et au 2ᵉ crash afficher `loadError = "La page a cessé de fonctionner"` (l'`ErrorOverlay` et son bouton Recharger existent déjà).
- **Effort** : 1 h. L'auto-test peut tuer le processus en DEBUG avec la SPI `_killWebContentProcess`, protégée par `responds(to:)`.

### 1.6 🟠 Alertes JS d'un onglet en arrière-plan : fenêtre modale de toute l'app — [V]
- `TabWebDelegate.swift:158-165` : si `webView.window == nil`, le code appelle `alert.runModal()`.
- Or `WebHost` n'attache que l'onglet sélectionné et les onglets « keep-alive » (`WebHost.swift:66-71`). Un onglet ouvert par ⌘-clic en arrière-plan n'a donc pas de fenêtre.
- **Scénario** : un site qui fait `alert()` ou `confirm()` au chargement dans un onglet en arrière-plan bloque toute l'application avec une modale venue d'un onglet invisible. Aucune protection non plus contre `while(1) alert()`.
- **Correctif** :
  - si l'onglet n'est pas affiché, le sélectionner d'abord (comportement Safari), ou mettre la demande en file jusqu'à la sélection ;
  - après 3 dialogues en moins de 10 s sur le même onglet, répondre automatiquement (`false` / `nil`).
- **Effort** : 1 h.

### 1.7 🟡 Suppression d'un espace : les données du site restent probablement sur le disque — [V] + [S]
- `BrowserModel.swift:361-365` : `WKWebsiteDataStore.remove(forIdentifier:)` est appelé alors que :
  - `space` (et donc `space._dataStore`) est encore vivant dans la portée ;
  - les vues web qui viennent d'être endormies ne sont peut-être pas encore désallouées ;
  - les espaces miroirs des fenêtres ⌘N gardent leur propre `_dataStore`.
- La documentation indique que la suppression échoue si le magasin est utilisé [S]. L'erreur est avalée (`{ _ in }`).
- **Scénario** : l'utilisateur supprime l'espace « Travail » en pensant effacer ses cookies ; ils restent sur le disque.
- **Correctif** :
  - vider `_dataStore` ;
  - différer la suppression au tour de boucle suivant ;
  - journaliser l'erreur et noter l'identifiant dans une liste « à supprimer » à rejouer au lancement suivant, avant toute création de vue web ;
  - dans l'auto-test, vérifier avec `fetchAllDataStoreIdentifiers` que l'identifiant a bien disparu.
- **Effort** : 1 à 2 h.
- À noter : la fonction d'auto-test crée elle aussi un espace de secours « Personnel » avec un UUID aléatoire (`BrowserModel.swift:110-118`), qui laisse un magasin persistant orphelin **à chaque exécution** [V]. Le dire à l'auto-test.

### 1.8 🟡 Fermeture de la fenêtre principale : les onglets continuent de vivre — [V] + [S]
- Aucun `tearDown` ni aucune mise en veille quand la scène SwiftUI `Window("Void")` se ferme : seules les fenêtres ⌘N/⌘⇧N passent par `BrowserWindows.windowWillClose`.
- `applicationShouldTerminateAfterLastWindowClosed` renvoie `false`.
- **Scénario** : une vidéo ou de l'audio tourne, l'utilisateur clique sur le bouton rouge. Les vues web restent détenues par les `Tab`, avec leurs processus. Le son continue probablement sans aucune interface [S].
- **Correctif** : dans `WindowAccessor`/`configure(window)`, observer `NSWindow.willCloseNotification` et mettre en pause les médias (`voidCall` pause) ou endormir les onglets non épinglés, sans les fermer, pour garder la session.
- **Effort** : 45 min.

### 1.9 🟡 `closeIfEmpty` peut supprimer définitivement un onglet épinglé — [V]
- `TabWebDelegate.swift:62-65` : si la première navigation d'un onglet se transforme en téléchargement, l'onglet est fermé avec `force: true`.
- Un onglet **épinglé**, restauré endormi, dont l'URL renvoie aujourd'hui un fichier (`Content-Disposition: attachment`), est donc supprimé définitivement au réveil.
- **Correctif** : `guard !tab.isPinned, tab.openedByPage || tab.url == navigation URL`.
- **Effort** : 10 min.

### 1.10 🟡 Courses mineures — [V]
- **`Tab.sleepKeepingPlace`** (`Tab.swift:159-166`) : il capture la vue web locale, puis attend jusqu'à 5 s (`voidCall`). Si l'onglet a été endormi puis réveillé entre-temps, `savedInteractionState` provient de l'**ancienne** vue et `sleep()` endort la nouvelle. Correctif : `guard self.webView === webView` après l'`await`.
- **Démarrage** (`Tab.swift:121` + `ContentRules.swift:25`) : pendant les 0,5 premières seconde, un chargement est différé par `whenReady`. Si l'utilisateur tape une URL entre-temps, `load(new)` part tout de suite, puis `whenReady` recharge l'**ancienne** URL restaurée par-dessus. Par ailleurs, les premières pages se chargent sans bloqueur quand la compilation dépasse 0,5 s (choix assumé).
- **`ReaderMode.toggle`** (`ReaderMode.swift:24-38`) : l'extraction est asynchrone. Si l'utilisateur navigue pendant ce temps, l'article de la page précédente s'affiche par-dessus la nouvelle. Correctif : comparer `webView.url` avant d'affecter `tab.reader`.
- **`DownloadManager.uniqueDestination`** (`:88-100`) : deux téléchargements simultanés du même nom obtiennent le même chemin, car le fichier n'existe pas encore. Le second échoue.

---

## 2. Sécurité et confidentialité (le risque est surtout architectural)

### 2.1 🔴 Remplissage automatique : identifiants injectés dans un cadre d'une autre origine — [V]
- `Features/Passwords/PasswordManager.swift:77-82` : si le remplissage dans `tab.loginFrame` ne renvoie pas `"ok"`, le code **retente dans le cadre principal** avec les identifiants de `tab.loginHost`, sans vérifier que le cadre principal a cette origine.
- `loginHost` et `loginFrame` peuvent venir d'une **iframe** (`:36-40`).
- **Scénario** : `evil.example` intègre une iframe de connexion `accounts.bank.com`, ce qui fait apparaître la clé 🔑. L'iframe ne correspond plus (navigation, champ caché), donc le remplissage dans le cadre renvoie `fail`. Le mot de passe de la banque est alors écrit dans le premier `input[type=password]` du cadre principal, qui appartient à la page hostile. L'autofill écrit dans le DOM, et la page le lit.
- Aggravant : `WKFrameInfo` est un instantané. Si l'iframe a navigué vers une autre origine, rien ne garantit que `callAsyncJavaScript(in: frame)` vise encore le bon document [S].
- **Correctif** :
  - passer l'hôte attendu à `__voidAutofill.fill(u, p, h)` et, dans `autofill.js`, refuser si `location.hostname` normalisé ne correspond pas (égalité ou sous-domaine) ;
  - supprimer le repli sur le cadre principal, ou le limiter au cas où l'hôte du cadre principal correspond.
- **Effort** : 1 h avec un auto-test (HTML avec une iframe `srcdoc` d'une autre `baseURL`, vérifier que le cadre principal reste vide).
- À noter aussi : `KeychainStore.logins(matching:)` (`:72-78`) accepte parent et enfant sans liste des suffixes publics. Un identifiant `site.github.io` est proposé sur `github.io`, et inversement. Risque faible, car Touch ID et un clic restent nécessaires.

### 2.2 🟠 Téléchargements probablement sans quarantaine — [S], à vérifier en 1 min
- L'app n'est pas sandboxée, et `Info.plist` n'a pas `LSFileQuarantineEnabled`.
- `DownloadManager` écrit directement dans `~/Downloads` **sans confirmation** (`decideDestination`).
- Si WebKit n'applique pas lui-même `com.apple.quarantine` (le fichier est écrit par le NetworkProcess), un `.app` ou un `.command` téléchargé en passant s'ouvre sans contrôle Gatekeeper.
- **Vérification** : `xattr -l ~/Downloads/<fichier téléchargé par Void>`.
- **Correctif** : dans `downloadDidFinish`, poser `URLResourceValues.quarantineProperties` (`kLSQuarantineAgentNameKey: "Void"`, `kLSQuarantineTypeKey: kLSQuarantineTypeWebDownload`, `kLSQuarantineDataURLKey`, `kLSQuarantineOriginURLKey`).
- **Effort** : 45 min, avec l'auto-test qui télécharge un `data:`/blob et lit l'attribut étendu.

### 2.3 🟠 Import : copies des bases Chrome laissées dans `/tmp` — [V]
- `Features/Import/BrowserImporter.swift:220-232` : `openCopy` copie `History`, `Login Data` (mots de passe chiffrés), `-wal` et `-shm` dans `temporaryDirectory/void-import-<uuid>/`, **et ne les supprime jamais**.
- **Correctif** : renvoyer le dossier et faire `defer { try? fm.removeItem(at: dir) }` dans l'appelant.
- **Effort** : 15 min.
- L'import s'exécute aussi entièrement sur le MainActor : 5 000 lignes d'historique, PBKDF2, puis un `SecItemAdd` par mot de passe. L'interface est gelée plusieurs secondes.

### 2.4 🟡 `core.js` modifie le DOM de toutes les pages — [V]
- `Resources/Scripts/core.js:26-42` : `allow="picture-in-picture; fullscreen"` et `allowfullscreen` sont ajoutés à **toutes** les iframes, pubs comprises.
- Un `MutationObserver` `subtree` sur tout le document appelle `querySelectorAll('iframe')` à chaque insertion de nœud avec enfants.
- Conséquences : coût mesurable sur les SPA lourdes, changement de la sémantique de sécurité voulue par la page (les iframes de pub peuvent passer en plein écran), et Void est détectable par les pages (empreinte).
- **Correctif** : limiter l'ajout aux iframes d'hôtes vidéo connus (youtube, vimeo, dailymotion, twitch…) et regrouper les mutations en lots.

### 2.5 🟡 Repli silencieux sur `BrowserModel.shared` — [V]
Sites concernés :
- `TabWebDelegate.swift:10` ;
- `VoidWebView.swift:70,77` ;
- `PasswordManager.swift:48` ;
- `DownloadManager.swift:58,124` ;
- `ReaderMode.swift:134`.

Quand `tab.browser` vaut nil (par exemple un événement tardif après la fermeture d'une fenêtre privée), l'action part dans la **fenêtre principale** : téléchargement listé dans l'historique normal, onglet ouvert dans la fenêtre normale. C'est aujourd'hui surtout théorique, mais c'est un piège pour toute évolution.

**Correctif** : si `tab.browser` vaut nil, abandonner l'événement plutôt que de le rediriger.

---

## 3. Performance et threading

- 🟠 **SQLite synchrone sur le thread principal** (`HistoryStore` est `@MainActor`) — [V] :
  - un `INSERT … ON CONFLICT` à chaque `didFinish` ;
  - un `UPDATE` **à chaque changement de titre** (KVO `Tab.swift:193-198`) : les sites qui font défiler leur titre ou affichent un compteur de notifications écrivent en continu ;
  - un `LIKE '%q%'` sur toute la table à **chaque frappe** dans la barre de commande (`CommandBar.swift:56`), sans WAL ni `busy_timeout` ;
  - `SQLiteDB.transaction` ne fait jamais de `ROLLBACK`.
  - **Correctif** : `PRAGMA journal_mode=WAL`, limiter `updateTitle` (uniquement si le titre diffère, au plus une fois toutes les 2 s par URL), exécuter les écritures sur une file série dédiée, et limiter la recherche aux 20 000 dernières entrées ou passer à FTS5. **Effort** : 2 h.
- 🟡 **Trousseau sur le thread principal** : `KeychainStore.logins()`, qui lit tous les éléments, est appelé à chaque message `form` de chaque cadre (`PasswordManager.swift:34`). À mettre en cache par hôte pendant la session.
- 🟡 **`saveNow()`** ré-encode tous les favicons (Data en base64 dans le JSON) à chaque `setNeedsSave`, c'est-à-dire à chaque `didFinish`, changement d'URL ou favicon. Acceptable jusqu'à environ 200 onglets. Les favicons iraient mieux dans un fichier ou un cache à part.
- 🟡 **`FaviconLoader`** : `URLSession.data(from:)` sans limite de taille ni délai court ; le cache par hôte est illimité.
- **Concurrence** : le projet est en `SWIFT_VERSION = 5.0` sans concurrence stricte. Les nombreux `MainActor.assumeIsolated` sont corrects aujourd'hui, puisque les rappels KVO, WK et Timer arrivent sur le thread principal, mais ils **plantent** à l'exécution si un rappel change de thread. Passer en `SWIFT_STRICT_CONCURRENCY = targeted` ferait ressortir les éventuels trous à la compilation. C'est un bon chantier pour une nuit, car il se vérifie par le build [V pour la configuration, S pour le nombre d'avertissements].

---

## 4. Architecture : ce qui freinera la suite

1. **Singletons omniprésents** : `BrowserModel.shared`, `PiPController.shared`, `FloatingPlayer.shared`, `ContentRules.shared`, `HistoryStore.shared`, `DownloadManager.shared`, `ExtensionManager.shared`, `ElementHider.shared`. Aucune injection, donc aucun test unitaire possible : l'auto-test tourne dans la vraie app et **touche des données réelles de l'utilisateur** (`ElementHider.reset(host: "example.com")` écrit dans `hidden-elements.json`, crée des magasins WebKit). Recommandation progressive : un protocole `Storage` injectable (répertoire racine) pour `StateStore`, `HistoryStore`, `ElementHider` et `BookmarkStore`, et un répertoire temporaire en mode auto-test.
2. **`BrowserModel` = état de fenêtre + politique d'onglets + persistance + PiP + toasts.** À 462 + 130 lignes, c'est encore gérable. Le prochain gros ajout (session multi-fenêtres, groupes d'onglets) devrait d'abord extraire un `SessionStore` (sérialisation, migration) et un `TabLifecycle` (veille, réveil, fermeture, PiP), qui concentrent aujourd'hui les bugs 1.2, 1.3, 1.9 et 1.10.
3. **Session limitée à la fenêtre principale** (`savesSession`, `BrowserModel.swift:427`) : ⌘Q fait perdre silencieusement tous les onglets des fenêtres ⌘N (documenté 🟡). Le format `SavedState` n'a pas de notion de fenêtre : c'est l'occasion de le versionner (voir 1.1) **avant** d'ajouter les fenêtres.
4. **État média calculé côté JS et « inféré »** : `hasVideo`, `isPlayingVideo`, `isAudible` et `isInPiP` sont reconstruits par agrégation de rapports sans cycle de vie (voir 1.4). À terme, s'appuyer sur `WKWebView.mediaPlaybackState`/`cameraCaptureState` (API publique) quand c'est possible, et garder `media.js` pour le PiP.
5. **Extensions** : sans adoption de `WKWebExtensionTab`/`WKWebExtensionWindow`, la plupart des extensions réelles (uBlock, gestionnaires de mots de passe) ne fonctionneront pas. De plus, activer les extensions ne touche pas les vues web existantes (la configuration est figée à la création). C'est un gros chantier (1 à 2 jours), pas pour cette nuit.
6. **Dépendance aux API privées** (`WebKitSPI.swift`) : bien isolée et protégée. Deux risques résiduels :
   - `setPreference` passe par KVC `setValue(forKey:)` après un test sur `_set<Key>:`. Si Apple garde le setter mais change le type, KVC lève une exception Objective-C (plantage) [S, peu probable] ;
   - `boolValue` fait un `unsafeBitCast` d'IMP vers `(AnyObject, Selector) -> Bool` : si la signature change, le comportement est indéfini.
   Ajouter en DEBUG une vérification dans l'auto-test qui journalise quelles SPI répondent, pour détecter une régression à chaque version de macOS.
7. **Aucune cible XCTest** : toute vérification passe par `-VoidSelfTest`, qui dépend du réseau (wikipedia, example.com). Les tests purement logiques (URLResolver, CSV, `voidNormalizedHost`, décodage de session, `ChromiumCrypto.decrypt`, `encodedRules`) mériteraient un mode `-VoidSelfTest unit` hors ligne et rapide.

---

## 5. TOP 5 des chantiers pour cette nuit

Chacun est faisable par un agent seul, en quelques heures, et vérifiable par `xcodebuild` (Debug, DerivedData **hors** ~/Documents) puis `-VoidSelfTest features` avec de nouveaux contrôles ajoutés dans `FeatureSelfTest.swift`.

| # | Chantier | Fichiers | Vérification auto-test | Effort |
|---|---|---|---|---|
| 1 | **Session incassable** : décodage tolérant (`decodeIfPresent`, `version`), sauvegarde du fichier illisible au lieu de l'écraser, récupération des espaces orphelins via `fetchAllDataStoreIdentifiers`, chemin injectable | `StateStore.swift`, `BrowserModel.swift` (restore) | Écrire un JSON tronqué puis un JSON « v2 » avec des champs inconnus ou manquants dans un dossier temporaire ; vérifier la restauration et la présence du `.corrupt` | 2–3 h |
| 2 | **Autofill limité à l'origine** : hôte attendu passé à `fill`, contrôle dans `autofill.js`, suppression du repli sur le cadre principal | `PasswordManager.swift`, `autofill.js` | Page `baseURL` A contenant une iframe `srcdoc`/B avec formulaire : `fill` pour B ne remplit jamais A, et `fill` sur un hôte différent renvoie `fail` (sans Touch ID : appeler directement le JS) | 1–1,5 h |
| 3 | **Cycle de vie des onglets en PiP ou flottants** (1.2, 1.3, 1.9) et **cadres média périmés** (1.4) : `pagehide` dans `media.js`, purge horodatée, `sleep` après `exit`, `closeIfEmpty` épargne les épinglés | `BrowserModel.swift`, `Tab.swift`, `PiPController.swift`, `media.js`, `TabWebDelegate.swift` | iframe vidéo en lecture puis `remove()` : `isPlayingVideo == false` en moins de 2 s ; ⌘W sur un épinglé avec `isInPiP` forcé : `isAsleep == true` au bout d'1 s | 2 h |
| 4 | **Robustesse aux crashs WebContent et dialogues JS** : veille des onglets en arrière-plan qui plantent, limite de rechargement et message d'erreur au premier plan, pas de `runModal` pour un onglet invisible, anti-spam des dialogues | `TabWebDelegate.swift` | Tuer le processus avec la SPI `_killWebContentProcess` (DEBUG, protégée) : un onglet en arrière-plan passe `isAsleep`, un onglet au premier plan recharge une fois puis affiche `loadError` au 2ᵉ crash ; `alert()` dans un onglet en arrière-plan ne bloque pas l'auto-test | 1,5–2 h |
| 5 | **Hygiène sécurité et disque** : quarantaine des téléchargements (2.2), nettoyage des copies temporaires de l'import (2.3), suppression effective du magasin d'un espace supprimé avec file de reprise (1.7), et pas de magasin orphelin créé par l'auto-test | `DownloadManager.swift`, `BrowserImporter.swift`, `BrowserModel.swift`, `Space.swift` | Télécharger un fichier de test et vérifier `com.apple.quarantine` (`getxattr`) ; après `deleteSpace`, l'identifiant est absent de `fetchAllDataStoreIdentifiers` | 2 h |

Chantiers suivants, si le temps le permet :
- (6) historique SQLite en WAL, limitation de `updateTitle` et écritures hors du thread principal ;
- (7) `SWIFT_STRICT_CONCURRENCY = targeted` et corrections qui en découlent ;
- (8) comportement à la fermeture de la fenêtre principale (1.8) ;
- (9) mise à jour du README : nombre de lignes, statut réel.

Garde-fous pour les agents de nuit :
- builder avec `-derivedDataPath` **hors d'iCloud** (voir la mémoire du projet) ;
- ne jamais lancer l'auto-test sur la vraie session : il s'isole déjà, sauf pour `hidden-elements.json` et les magasins WebKit (voir §4.1) ;
- un commit par chantier, avec le rapport d'auto-test dans `docs/selftest/`.
