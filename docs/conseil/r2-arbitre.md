# Conseil des agents, tour 2 : rapport de l'Arbitre

J'ai relu le code de la branche `nuit-conseil` en lecture seule, jusqu'au commit c31c821 « Mots de passe : remplissage verrouillé… ». Les numéros de ligne renvoient au code de 40cb9b0, sauf mention contraire.

Légende :
- **CONFIRMÉ** : le code dit bien ce que le rapport affirme ;
- **NUANCÉ** : c'est vrai, mais la portée ou le correctif diffèrent ;
- **INCERTAIN** : cela dépend de WebKit ou de macOS, et seul un test permet de trancher (le test est proposé).

---

## 1. Vérification des constats lourds

### 1.1 Autofill : repli sur le cadre principal — CONFIRMÉ, puis CORRIGÉ (c31c821)

**Ce qui a été confirmé**
- `PasswordManager.swift:77-82` (40cb9b0) : si le cadre du formulaire ne renvoie pas `ok`, le code retente sans `in:`, donc dans le cadre principal, sans aucun contrôle d'origine.
- Le commit c31c821 supprime ce repli et prend l'hôte dans `frame.securityOrigin`.
- `autofill.js` vérifie maintenant l'hôte et le protocole attendus avant d'écrire.
- Un auto-test couvre le cas.

**Ce qui reste, en petit** (à glisser dans le chantier 5, ~20 min)
- `TabWebDelegate.swift:73-80` : `didCommit` vide `loginAccounts`, mais pas `loginHost` ni `loginFrame`. `Tab.sleep()` ne les vide pas non plus.
- `PasswordManager.swift:36` : une iframe qui a des comptes remplace le formulaire du cadre principal, même si elle est d'un autre site. Safari refuse de remplir une iframe dont le site diffère de celui du cadre principal.
- **http et https restent confondus.** `expectedProtocol` vient du protocole *actuel* du cadre, pas de celui sous lequel l'identifiant a été enregistré. Un mot de passe enregistré en https est donc toujours rempli sur `http://meme-site`. Correctif : refuser de remplir quand le cadre est en `http:` et que l'identifiant vient du trousseau, où il est enregistré en `kSecAttrProtocolHTTPS`.
- `autofill.js` : les `click` ne sont pas filtrés par `isTrusted`, ce qui laisse la page déclencher l'invite « Enregistrer le mot de passe ».

### 1.2 Barre d'adresse sur l'URL provisoire — code CONFIRMÉ, comportement de WebKit très probable

- `Tab.swift:200-204` : `tab.url` suit le KVO de `webView.url` sans aucun filtre.
- `AddressPill.swift:40` : le cadenas se résume à `scheme == "https"`.
- `AddressPill.swift:50-53` : `addressText` affiche l'hôte de `tab.url`.
- Côté WebKit, `WKWebView.url` renvoie `PageLoadState::activeURL`. Pendant l'état *Provisional*, c'est l'URL provisoire. Je le tiens de ma connaissance des sources de WebKit, sans l'avoir mesuré.
- Le scénario d'usurpation est donc crédible : la page lance une navigation vers `banque.fr`, la navigation reste en attente, et la barre affiche « banque.fr » avec le cadenas au-dessus du contenu hostile.

**Test qui tranche** (à écrire *avant* le correctif et à voir échouer) :
1. Dans l'auto-test, lancer un `NWListener` local sur 127.0.0.1 qui accepte les connexions sans jamais répondre, ce qui rend l'attente déterministe et hors réseau.
2. Ouvrir une page `loadHTMLString(baseURL: https://void-a.example/)` qui fait `location = 'http://127.0.0.1:PORT/'`.
3. Une seconde plus tard, vérifier `tab.addressText == "void-a.example"`.

### 1.3 Téléchargements sans quarantaine — code CONFIRMÉ, effet INCERTAIN

**Ce qui est sûr**
- Aucune occurrence de « quarantine » dans le dépôt.
- `Config/Info.plist` n'a pas de `LSFileQuarantineEnabled`.
- L'app n'est pas sandboxée (`Config/Void.entitlements`).
- `downloadDidFinish` (`DownloadManager.swift:115-126`) ne pose aucun attribut.
- « Ouvrir » dans la Bibliothèque appelle `NSWorkspace.open` (`:73-76`).

**Ce qu'on ne sait pas.** Le fichier est écrit par le processus réseau de WebKit (`com.apple.WebKit.Networking`), pas par Void. De mémoire, `Download::platformDidFinish` dans `DownloadCocoa.mm` *met à jour* les propriétés de quarantaine (agent, URL d'origine) quand elles existent déjà. Je ne peux pas affirmer que le processus réseau les crée lui-même pour une app hôte non sandboxée. Aucun rapport ne l'a mesuré.

**Test concret, qui sert aussi de diagnostic :**
1. Régler `AppSettings.downloadFolder` sur un dossier temporaire (et le restaurer ensuite).
2. Charger une page locale avec `<a download="void-test.command" href="data:application/octet-stream;base64,...">` et appeler `a.click()` par JS. `shouldPerformDownload` passe alors par `adopt`. Si le clic scripté ne déclenche rien, repli : `webView.startDownload(using:)` puis `DownloadManager.shared.adopt(...)`.
3. Attendre `state == .finished`.
4. **Journaliser dans le rapport** si `getxattr(path, "com.apple.quarantine")` existait *avant* l'intervention de Void : c'est la réponse à la question posée sur WebKit.
5. Vérifier ensuite que l'attribut est présent et contient l'agent « Void ».

**Désaccord tranché : je refuse `LSFileQuarantineEnabled = YES`** (proposé par le rapport Sécurité).
- Cette clé met en quarantaine *tout ce que le processus de Void écrit* : `session.json`, `history.sqlite`, les fichiers de réglages, les copies d'import.
- Elle ne couvre pas les fichiers écrits par le processus réseau de WebKit, c'est-à-dire justement les téléchargements.

On pose donc explicitement `URLResourceValues.quarantineProperties` dans `downloadDidFinish`. Ce correctif est sans regret, même si WebKit posait déjà l'attribut.

### 1.4 `session.json` illisible → espaces recréés et déconnexion générale — CONFIRMÉ, avec des nuances

- `StateStore.swift:37-40` : `try? JSONDecoder().decode`, donc tout ou rien.
- `BrowserModel.swift:121-126` : en cas d'échec, Void recrée « Personnel » et « Travail » avec de **nouveaux UUID**.
- `Space.swift:40` : `WKWebsiteDataStore(forIdentifier: id)`. Avec de nouveaux UUID, les cookies de chaque espace sont perdus (restent orphelins sur le disque).
- La sauvegarde suivante (`saveNow`, `BrowserModel.swift:437-448`, déclenchée environ une seconde après le premier `didFinish`) écrase alors l'original.

**Nuances**
- L'écriture est `.atomic`, donc un fichier tronqué par un crash est peu probable.
- Les causes réalistes sont ailleurs :
  - une évolution du format : un champ non optionnel ajouté, alors que `version` n'est jamais lu ;
  - **une seule URL invalide dans un seul onglet** : le décodage `Codable` de `URL` échoue et toute la session tombe avec lui ;
  - une modification manuelle du fichier.

**Désaccord tranché : je refuse cette nuit la « récupération des magasins orphelins par `fetchAllDataStoreIdentifiers` »** (proposée par l'Architecte). Chaque exécution de l'auto-test crée des espaces persistants (« Self-test », « Self-test B ») dont les magasins restent probablement sur le disque. La récupération automatique ressusciterait des dizaines d'espaces « Récupéré ». À la place :
1. sauvegarder le fichier illisible sous `session.corrupt-<date>.json` ;
2. décoder avec tolérance, élément par élément ;
3. si le JSON est lisible mais ne correspond pas au format, récupérer au moins les `id`, `name` et `icon` des espaces par `JSONSerialization`, pour **garder les UUID et donc les connexions**.

### 1.5 `media.js` : MutationObserver et `querySelectorAll('*')` — CONFIRMÉ, avec des nuances

- `media.js:19-21` : `videos()` ne trouve rien dans le DOM normal, puis fait `collect(document, [], 3)`, qui revient à `querySelectorAll('*')` récursif dans les shadow roots.
- `media.js:118-122` : ce parcours est rappelé à chaque **lot** de mutations (pas à chaque nœud) pendant 30 s, dans chaque cadre, et seulement tant qu'aucune vidéo n'est trouvée.
- Le coût est réel sur les fils infinis et les grosses SPA, mais borné à 30 s par document. C'est une gêne, pas un bug.
- Autre point CONFIRMÉ : aucun `pagehide`. Une iframe vidéo retirée laisse une entrée `playing` dans `mediaFrames`, qui n'est remise à zéro qu'au commit du cadre principal (`TabWebDelegate.swift:79`). C'est ce défaut qui a des effets visibles : icône son, onglet jamais mis en veille, tentative d'auto-PiP.

**Correctif le moins risqué pour le PiP** : garder la sémantique, mais **limiter** le parcours profond à une fois par seconde, ajouter `pagehide` et purger côté Swift les entrées trop anciennes. On ne réécrit pas la détection.

### 1.6 SQLite sans WAL, sur le thread principal — CONFIRMÉ, avec des nuances

- `SQLiteDB.swift:9-15` : aucun `PRAGMA`.
- `SQLiteDB.swift:34-38` : `transaction` n'a pas de `ROLLBACK`.
- `HistoryStore` est `@MainActor`.
- `Tab.swift:197` : un `UPDATE` à chaque changement de titre, même si le titre est identique.
- `HistoryStore.swift:44-50` : `LIKE '%q%'` à chaque frappe.

**Nuances**
- Sur macOS, SQLite fait un `fsync` sans `F_FULLFSYNC` par défaut, et ce n'est pas cher sur APFS/SSD. Le gain est modéré, mais WAL + `synchronous=NORMAL` coûtent deux lignes et ne présentent aucun risque.
- Déplacer l'historique sur une file dédiée est plus invasif. **Je le reporte.**

**Nouveau constat [CONFIRMÉ]** : `updateTitle` (`Tab.swift:197`) ne teste que `isPrivate`, pas `browser.isEphemeralSession`. Pendant l'auto-test, les onglets écrivent donc des titres dans le **vrai** `history.sqlite`. Seuls les URL déjà présentes sont touchées (`UPDATE`), mais c'est une fuite de l'auto-test vers les données réelles.

### 1.7 Robustesse des onglets — CONFIRMÉ (4 points)

- **Dialogues JS** : `TabWebDelegate.swift:158-165` appelle `runModal()` dès que `webView.window == nil`, ce qui est le cas de tout onglet en arrière-plan. Une modale bloque alors toute l'application, et rien n'arrête un `while(1) alert()`.
- **Crash du processus web** : `TabWebDelegate.swift:108-110` recharge sans condition, ce qui peut produire une boucle.
- **Onglet épinglé supprimé** : `TabWebDelegate.swift:62-65`, `closeIfEmpty` appelle `close(force: true)`. Un onglet épinglé restauré endormi, dont l'URL renvoie maintenant un fichier, est supprimé définitivement au réveil : c'est une **perte de données**.
- **⌘W sur un épinglé en PiP** : `BrowserModel.swift:191-195` lance `exit` en asynchrone puis appelle `sleep()` tout de suite. Or `Tab.swift:136` sort sans rien faire tant que `isInPiP` est vrai, donc l'onglet ne dort pas alors que le toast dit le contraire.

### 1.8 Autres constats vérifiés

| Constat | Verdict | Fichier et ligne |
|---|---|---|
| Copies `History` et `Login Data` jamais effacées de `$TMPDIR` | CONFIRMÉ | `BrowserImporter.swift:220-232` |
| Le bloqueur retire l'ancienne liste avant de compiler la nouvelle | CONFIRMÉ | `ContentRules.swift:51-52` |
| Favicons : une seule session `.ephemeral` pour normal et privé (cookies partagés en mémoire) | CONFIRMÉ | `FaviconLoader.swift:7` |
| `core.js` donne `fullscreen` à toutes les iframes | CONFIRMÉ ; NUANCÉ car le plein écran exige un geste | `core.js:26-32` |
| Schémas externes ouverts sans confirmation, même depuis une iframe | CONFIRMÉ | `TabWebDelegate.swift:23-26` |
| Suppression d'un espace : magasin peut-être encore utilisé | INCERTAIN (`releaseStore` est bien appelé, mais la variable locale `space._dataStore` et les vues web sont peut-être encore vivantes) | `BrowserModel.swift:361-365` |

---

## 2. Arbitrage des désaccords

**Fonctionnalités visibles ou robustesse ?** La robustesse passe d'abord.
- Personne ne vérifiera le résultat avant le matin. Un bug de perte de données ou d'usurpation introduit ou laissé cette nuit coûte plus cher que n'importe quelle nouveauté.
- Les deux améliorations visibles retenues (palette de commandes, zoom par site) sont celles qui se testent **entièrement par le modèle**, sans clic ni regard humain, et qui ne touchent ni la session ni le WebKit partagé.
- Les idées produit des rapports Produit et Vision (suggestions distantes, onboarding, archivage) demandent une décision de goût ou de vie privée : c'est à l'humain de les prendre.

**EasyList cette nuit ?** Non. Rapport Perf contre rapports Produit et Vision : je suis ces derniers pour cette nuit.
- Il faut un téléchargement réseau et une conversion d'environ 300 lignes.
- Le temps de compilation et la mémoire d'une liste de 100 000 règles ne sont pas mesurés.
- Le coût des sélecteurs cosmétiques génériques sur le calcul de style n'est pas maîtrisé.
- Il n'y a aucun moyen de constater une casse de sites sans humain.

En revanche, on fait **cette nuit son prérequis sans risque** (chantier 5) : ajouter la nouvelle liste avant de retirer l'ancienne, et nettoyer les listes `void-*` orphelines. Choix à trancher plus tard : téléchargement au premier lancement avec la liste maison en repli (rapport Perf), plutôt qu'une liste figée au build.

**App Intents ou schéma `void://` ?** Report, pour quatre raisons.
- La découverte par Raccourcis n'est pas testable sans humain, et la valeur perçue dépend d'une signature stable.
- **`void://` ouvre une surface d'attaque** : n'importe quelle page web peut déclencher un lien `void://open?...`. Il faut d'abord une politique décidée à tête reposée (confirmation, liste de schémas autorisés, jamais de fenêtre privée ni d'espace ciblé sans geste).
- Les intents appelés app fermée demandent une file d'attente au démarrage, c'est-à-dire une nouvelle voie vers le modèle.
- C'est une bonne orientation à six mois (rapport Vision), pas un chantier de nuit.

**Autres arbitrages**
- **Archivage automatique des onglets** (rapport Vision n°4) : report. C'est contraire à la priorité « non-perte de données » tant que la session n'est pas incassable (chantier 1).
- **Index plein texte FTS5** : report. C'est une décision de vie privée (exclusions, stockage du texte lu) qui revient à l'humain.
- **`SWIFT_STRICT_CONCURRENCY = targeted`** (rapport Architecte) : report. Le diff serait bruyant et diffus, et risquerait de noyer les vrais correctifs de la nuit. À faire seul sur une autre branche.

---

## 3. Plan de nuit (branche à part, un commit par chantier)

**Règles communes**
- Builder en Debug avec `-derivedDataPath` **hors de `~/Documents`** (iCloud casse la signature).
- Lancer `Void -VoidSelfTest features` après chaque chantier, et aussi l'auto-test PiP après les chantiers 4 et 9.
- **Pour les deux constats incertains (1.2, 1.3), écrire le test d'abord**, le lancer, noter dans le rapport s'il échoue, puis corriger.
- Aucun contrôle ne doit reposer sur un clic simulé : on passe par des appels directs au modèle, au délégué ou au JS (`voidCall`).
- Aucun test ne touche la vraie session ni le vrai historique.

### Chantier 1 — Session incassable (non-perte de données)

**Objectif**
- Ne plus jamais perdre les espaces, leurs UUID ni les épinglés à cause d'un `session.json` illisible ou d'un changement de format.

**Travaux**
- Écrire `StateStore.decode(_ data: Data) -> SavedState?`, une fonction pure et tolérante :
  - `init(from:)` avec `decodeIfPresent` pour les champs non essentiels ;
  - décodage des onglets **élément par élément**, pour qu'un onglet invalide (par exemple une URL invalide) soit ignoré au lieu de tout faire tomber ;
  - URL décodées en `String` puis `URL(string:)`.
- Si le décodage échoue :
  - copier le fichier en `session.corrupt-<horodatage>.json` ;
  - récupérer `id`, `name` et `icon` des espaces par `JSONSerialization` si c'est possible ;
  - poser un drapeau `restoredFromCorrupt` qui empêche d'écraser le fichier avant qu'une restauration partielle ait abouti.
- Rendre le répertoire injectable : `load(from dir:)` et `save(_:to:)`.
- Lire `version` et le passer à 2 **seulement** si un champ est ajouté.

**Fichiers** : `Browser/StateStore.swift`, `Browser/BrowserModel.swift` (init et restore).

**Vérification** (nouveaux contrôles dans `FeatureSelfTest.swift`, sur des données construites en mémoire et un dossier temporaire) :
- un JSON valide fait l'aller-retour à l'identique ;
- des champs inconnus sont ignorés et les espaces sont restaurés avec **les mêmes UUID** ;
- un onglet avec une URL invalide laisse les autres onglets et l'espace intacts ;
- un JSON tronqué produit un fichier `.corrupt-*` dans le dossier temporaire, et `load` ne l'écrase pas ;
- un JSON lisible mais hors format permet de récupérer les UUID des espaces.

**Effort** : 2 à 2,5 h.

**Risque de régression** : moyen. Le chemin de lancement réel n'est pas exercé par l'auto-test, qui ne lit jamais la session. Il faut donc garder le chemin nominal strictement identique : même structure de données et mêmes clés JSON à l'écriture.

### Chantier 2 — Barre d'adresse sur l'URL validée

**Objectif**
- Empêcher l'usurpation par une navigation lancée par la page qui n'aboutit jamais.

**Travaux**
- `tab.url` n'est plus mis à jour par le KVO de `webView.url` pendant une navigation provisoire. Il l'est :
  - au `didCommit` ;
  - par le KVO seulement si la nouvelle URL a **la même origine** que l'URL validée (`pushState`, ancres).
- `Tab.load` (saisie de l'utilisateur) continue de fixer `url` immédiatement.
- Cadenas : https **et** `webView.hasOnlySecureContent`, observé par KVO.

**Fichiers** : `Browser/Tab.swift`, `Web/TabWebDelegate.swift`, `UI/AddressPill.swift`.

**Vérification**
- Le test du `NWListener` qui ne répond jamais (§1.2) : `addressText == "void-a.example"` au bout d'une seconde.
- `pushState('/x')` met bien à jour `tab.url`.
- Une navigation vers une autre page locale qui aboutit met à jour `tab.url` après le commit.
- Les contrôles existants (⌘-clic, `_blank`, veille et réveil) restent verts.

**Effort** : 1,5 à 2 h.

**Risque de régression** : moyen. `tab.url` alimente la session, les favoris, le mode lecture et le bloqueur par site. On ne fait que retarder sa mise à jour jusqu'au commit.

### Chantier 3 — Téléchargements et ouvertures externes sûrs

**Objectif**
- Quarantaine garantie, noms de fichiers sains, pas d'app externe lancée par une iframe.

**Travaux**
- Dans `downloadDidFinish`, poser `quarantineProperties` si elles sont absentes : agent « Void », type web download, URL d'origine.
- `uniqueDestination` :
  - retirer les caractères de contrôle et les caractères bidi (U+202A–202E, U+2066–2069) ;
  - retirer le `.` initial ;
  - limiter la longueur à 200 ;
  - réserver le nom pendant le téléchargement, pour que deux téléchargements simultanés du même nom ne tombent pas sur le même chemin.
- Nouvelle fonction pure `ExternalURLPolicy.decide(url:isMainFrame:)` :
  - refus pour `smb`, `afp`, `nfs`, `cifs`, `ftp`, `vnc`, `ssh`, `telnet`, `file` ;
  - refus depuis un sous-cadre ;
  - `mailto:` et `tel:` autorisés ;
  - pour le reste, `NSAlert` « Ouvrir “App” ? ».
- Menu contextuel : n'ouvrir que les liens `http`, `https` et `about`.

**Fichiers** : `Features/Library/DownloadManager.swift`, `Web/TabWebDelegate.swift`, `Web/VoidWebView.swift`.

**Vérification**
- Le test de quarantaine du §1.3 (avec le diagnostic « présente avant Void : oui/non » dans le rapport).
- `uniqueDestination("facture\u{202E}fdp.app")` ne contient plus U+202E.
- Deux réservations du même nom donnent deux chemins différents.
- Table de cas pour `ExternalURLPolicy` : `smb` refusé, sous-cadre refusé, `mailto` autorisé.

**Effort** : 2 h.

**Risque** : faible. Le dialogue pour les schémas inconnus est la seule partie qui ne se teste pas : ne tester que la fonction pure.

### Chantier 4 — Cycle de vie des onglets (plantages, dialogues, épinglés, PiP)

**Objectif**
- Plus de modale bloquante venue d'un onglet invisible, plus de boucle de rechargement, plus d'épinglé supprimé.

**Travaux**
- **Dialogues JS**
  - si l'onglet n'est pas affiché (`webView.window == nil`), répondre par la valeur par défaut (`alert` : rien, `confirm` : false, `prompt` : nil) et afficher un toast « Un onglet a tenté d'afficher une alerte » ;
  - au-delà de 3 dialogues en 10 s sur le même onglet, répondre automatiquement.
- **Crash WebContent**
  - onglet non affiché : `sleep()`, il se rechargera au clic ;
  - onglet affiché : un seul rechargement par tranche de 30 s, puis `loadError = "La page a cessé de fonctionner"`.
- **`closeIfEmpty`** : ne jamais fermer un onglet épinglé, ni un onglet qui n'a pas été ouvert par la page.
- **Fermeture en PiP**
  - dans `close` (branche épinglée), faire `Task { await exit; sleep() }` et fermer `FloatingPlayer` ;
  - dans les branches forcées et dans `tearDown`, remettre `isInPiP` et `isInFloatingPlayer` à false avant `sleep()`.

**Fichiers** : `Web/TabWebDelegate.swift`, `Browser/BrowserModel.swift`, `Browser/Tab.swift`.

**Vérification** (appels directs au délégué, sans SPI ni clic) :
- `voidCall("alert('x'); return 'ok'")` sur un onglet en arrière-plan répond en moins de 2 s ; sans correctif, l'auto-test resterait bloqué, donc l'appel est encadré par un délai maximal ;
- `delegate.webViewWebContentProcessDidTerminate(wv)` sur un onglet d'arrière-plan donne `isAsleep`. Sur l'onglet affiché, un premier appel recharge, un second donne `loadError != nil` ;
- un épinglé avec `isInPiP = true` forcé, puis ⌘W par le modèle (`browser.close(tab)`), donne `isAsleep` au bout d'une seconde ;
- un onglet épinglé dont la navigation devient un téléchargement (lien `data:` avec `Content-Disposition`, ou appel direct de `closeIfEmpty` via la méthode du délégué) reste dans `space.pinned`.

**Effort** : 2 h.

**Risque** : moyen, puisque le PiP est concerné. Lancer aussi l'auto-test PiP.

### Chantier 5 — Hygiène vie privée et disque (petits correctifs groupés)

**Travaux**
- Import : `defer { removeItem(dir) }` après fermeture de la base copiée.
- Favicons :
  - session sans cookies ni cache (`httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCache = nil`) ;
  - `timeoutIntervalForRequest = 10` ;
  - taille maximale de 512 Ko ;
  - cache mémoire borné à 500 hôtes.
- Bloqueur : ajouter la nouvelle liste **puis** retirer l'ancienne ; supprimer les identifiants `void-*` inactifs du store (`getAvailableContentRuleListIdentifiers` / `removeContentRuleList`).
- `core.js` : `picture-in-picture` pour toutes les iframes (le PiP en dépend), `fullscreen` seulement pour les hôtes vidéo connus (youtube, vimeo, dailymotion, twitch).
- Mots de passe (reliquats du §1.1) :
  - `loginHost` et `loginFrame` remis à `nil` au `didCommit` et dans `sleep()` ;
  - refus du remplissage en http d'un identifiant https ;
  - pas d'iframe d'un autre site que le cadre principal ;
  - `isTrusted` dans `autofill.js` ;
  - `contextLinkURL` remis à `nil` au commit.
- Auto-test : `updateTitle` ne doit rien écrire quand `browser.isEphemeralSession` est vrai (§1.6).

**Fichiers** : `BrowserImporter.swift`, `FaviconLoader.swift`, `ContentRules.swift`, `core.js`, `PasswordManager.swift`, `autofill.js`, `TabWebDelegate.swift`, `Tab.swift`.

**Vérification**
- `FaviconLoader.session.configuration.httpCookieStorage == nil`.
- Aucun dossier `void-import-*` ne reste après un `openCopy` suivi de sa fermeture (rendre la fonction accessible en interne).
- Après 5 bascules de la liste blanche, `adBlockList != nil` à chaque instant (observation) et au plus 2 identifiants `void-adblock-*` dans le store.
- Une iframe publicitaire insérée a `allow` sans `fullscreen` ; une iframe `youtube.com/embed` l'a.
- Après une navigation, `loginHost == nil`.
- Une page `http://` avec `loginHost` https : `inject` renvoie `origin`.

**Effort** : 1,5 à 2 h.

**Risque** : faible à moyen. `core.js` touche le PiP intégré, donc relancer l'auto-test PiP.

### Chantier 6 — Historique SQLite plus sobre

**Travaux**
- À l'ouverture : `PRAGMA journal_mode=WAL; synchronous=NORMAL; busy_timeout=2000`.
- `ROLLBACK` si le corps de `transaction` échoue : il renvoie un booléen.
- `updateTitle` n'écrit que si le titre diffère du dernier écrit pour cet onglet.
- Barre de commande :
  - suggestions calculées dans un `@State` sur `onChange(of: text)`, et non plus dans `body` ;
  - identifiants stables (type + URL) au lieu de `UUID()`, ce qui évite de tout recalculer au survol.

**Fichiers** : `SQLiteDB.swift`, `HistoryStore.swift`, `Tab.swift`, `UI/CommandBar.swift`.

**Vérification**
- `PRAGMA journal_mode` renvoie `wal`, via un accesseur réservé au DEBUG.
- Deux appels à `SuggestionEngine.suggestions(for: "exa")` donnent des `id` identiques.
- Avec un compteur DEBUG, 10 changements de titre identiques produisent au plus 1 écriture.

**Effort** : 1,5 h.

**Risque** : faible. Le passage en WAL est définitif pour le fichier, ce qui est compatible avec tout le reste.

### Chantier 7 — [Visible] Palette de commandes (`>` dans ⌘L)

**Objectif**
- Taper `>` dans la barre de commande donne accès à toutes les actions :
  - thème ;
  - mode lecture ;
  - épingler ou désépingler ;
  - aller à l'espace X ;
  - nouvelle fenêtre privée ;
  - masquer ou afficher les onglets ;
  - fermer les autres onglets ;
  - fermer les doublons ;
  - réglages ;
  - importer.
- Recherche floue simple (sous-séquence et score), qui s'appuie sur le cas `.action` qui existe déjà.

**Fichiers** : `UI/CommandBar.swift` (nouveau `CommandCatalog`), `Browser/BrowserModel+Actions.swift` (ajout de `closeOtherTabs` et `closeDuplicates`).

**Vérification**
- `suggestions(for: ">thème")` contient la commande attendue.
- L'exécuter change `AppSettings.theme`, puis la valeur est restaurée.
- `">doublons"` ferme les doublons de l'espace de test : `space.tabs` est vérifié, et les onglets fermés sont récupérables par ⌘⇧T via `closedTabs`.
- La commande est sans effet dans une fenêtre privée quand elle ne s'y applique pas.

**Effort** : 2 à 2,5 h.

**Risque** : faible, car c'est un ajout pur.

### Chantier 8 — [Visible] Zoom mémorisé par site

**Objectif**
- ⌘+ et ⌘− sont retenus par hôte et réappliqués au commit, au réveil et au relancement.
- ⌘0 remet à zéro et oublie l'hôte.
- Rien n'est mémorisé en fenêtre privée.

**Fichiers** : `AppSettings.swift` (`[String: Double]` dans `UserDefaults`), `BrowserModel+Actions.swift`, `TabWebDelegate.swift` (`didCommit`).

**Vérification**
- Régler 1,25 sur une page `void-zoom.example`, endormir puis réveiller l'onglet : `pageZoom == 1.25`.
- Ouvrir un autre onglet sur le même hôte : 1,25.
- En fenêtre privée, rien n'est mémorisé.
- Nettoyer la clé en fin de test.

**Effort** : 1 h.

**Risque** : faible.

### Chantier 9 (si le temps le permet) — `media.js` sobre et cadres média périmés

**Travaux**
- Parcours profond limité à une fois par seconde dans le rappel du `MutationObserver`.
- `getElementsByTagName('video')` en premier.
- `pagehide` envoie un rapport avec `hasVideo`, `playing`, `audible` et `inPiP` à false.
- Côté Swift, horodater les entrées de `mediaFrames` et purger celles qui ont plus de 60 s dans `sleepInactiveTabs`.

**Fichiers** : `media.js`, `PiPController.swift`, `BrowserModel.swift`.

**Vérification**
- Compteur DEBUG `__voidMedia._deepScans` lu par `voidCall`, sur une page de 5 000 nœuds sans vidéo après 200 mutations : au plus 5.
- Une entrée `mediaFrames` injectée avec une date ancienne est purgée et `isPlayingVideo` redevient false.
- **L'auto-test PiP complet doit rester vert.** Sinon, annuler le commit.

**Effort** : 1,5 h.

**Risque** : moyen à élevé, car la détection des vidéos dans les shadow roots est en jeu. C'est pour cela que le chantier est en dernier.

### Chantier 10 — README honnête et rapport d'auto-test

- Mettre à jour le nombre de lignes (environ 8 050, contre « ~5 700 » annoncées).
- Mettre à jour le statut des fonctions : ✅ seulement si un contrôle automatique existe.
- Ajouter une section « Robustesse » qui liste ce qui a été corrigé cette nuit.
- Commit de `docs/selftest/features.md`.
- **Effort** : 20 min. **Risque** : nul.

**Ordre à suivre** : 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → (9) → 10. Si un chantier ne passe pas l'auto-test après deux essais, faire `git revert` de son commit, le noter dans le rapport et passer au suivant.

---

## 4. À refuser ou à reporter explicitement

| Proposition | Décision | Pourquoi |
|---|---|---|
| EasyList / EasyPrivacy (convertisseur, téléchargement) | Reporter | Réseau, compilation et mémoire non mesurés, casse de sites invisible sans humain. Le prérequis (échange de listes sans trou) est fait au chantier 5. |
| App Intents, schéma `void://` | Reporter | Pas testable sans humain. `void://` crée une surface d'attaque à concevoir d'abord. |
| `LSFileQuarantineEnabled` dans Info.plist | Refuser | Met en quarantaine les propres fichiers de Void et ne couvre pas le processus réseau de WebKit. |
| Récupération automatique des magasins orphelins | Refuser pour l'instant | Les magasins laissés par l'auto-test ressusciteraient en espaces fantômes. Il faut d'abord que l'auto-test nettoie ses magasins. |
| Archivage automatique des onglets | Reporter | Risque de perte perçue ; attendre la session incassable et une décision produit. |
| Index plein texte FTS5, Foundation Models | Reporter | Décision de vie privée ; FTS5 n'est pas déterministe à tester, et Foundation Models demande macOS 26. |
| Suggestions de recherche distantes | Reporter | Envoie les frappes à un tiers : décision de l'humain (moteur, désactivation par défaut ?). |
| Onboarding (thème Système par défaut, choix du moteur, étape d'import) | Reporter | Choix produit ; changer un défaut sans humain surprend. |
| Permissions caméra et micro par site, tiroir de téléchargements, confirmation des téléchargements en rafale depuis une iframe | Reporter | Interface et invites à valider à l'œil. |
| `SWIFT_STRICT_CONCURRENCY = targeted` | Reporter (branche dédiée) | Diff diffus qui masquerait les correctifs de la nuit. |
| Historique sur une file série, retrait des singletons, injection du stockage | Reporter | Refactor transversal, trop de surface pour une nuit sans relecture. |
| Extensions (permissions affichées, copie du code, `chrome.tabs`) | Reporter | Pas testable sans extension réelle. |
| Pastille d'origine en mode onglets masqués, sortie de PiP qui vole le focus | Reporter | Interface et heuristique à valider à la main. |
| Fermeture de la fenêtre principale qui laisse tourner le son | Reporter | Comportement de la scène SwiftUI à observer à l'œil. |
| Synchronisation, passkeys, cartes bancaires, pubs YouTube, vue scindée, Handoff, Web Push | Refuser | Compte développeur, backend ou course aux armements ; hors de la mission. |
| Glisser-déposer dans la barre du haut | Refuser | Décision déjà actée (5 essais). |
