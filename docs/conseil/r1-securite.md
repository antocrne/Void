# Conseil des agents — R1 Sécurité & vie privée (Void)

Branche `nuit-conseil`, commit 40cb9b0. Audit **en lecture seule** : rien n'a été exécuté contre l'app. Chaque constat est marqué
**VÉRIFIÉ** (lu dans le code, chemin d'exécution suivi) ou **SUPPOSÉ** (dépend d'un comportement de WebKit/macOS non testé ici ; la façon de vérifier est indiquée).

Gravité : 🔴 haute · 🟠 moyenne · 🟡 basse · ⚪ info / bon point.

---

## 0. Ce qui est déjà solide (à garder)

- ⚪ **Ponts JS → natif limités au monde isolé** : les 5 handlers sont enregistrés avec `contentWorld: world` (`Web/WebViewFactory.swift:14-16`). Dans le monde de la page, `window.webkit.messageHandlers.voidAutofill` n'existe pas : une page hostile **ne peut pas poster** de message ni lire `window.__voidAutofill` (VÉRIFIÉ dans le code, garantie WebKit). Les appels natifs → JS passent aussi par le monde « Void » (`voidCall`, `WebViewFactory.swift:85`).
- ⚪ **Secrets hors du disque** : mots de passe dans le trousseau uniquement (`KeychainStore`), lecture du secret seulement après `BiometricGate` (`PasswordManager.swift:75-76`, `SettingsView.swift:422-431`). La liste des comptes se lit sans lire les secrets.
- ⚪ **SQL paramétré** (`SQLiteDB.swift:48-53`) ; requêtes d'import constantes.
- ⚪ **TLS** : aucun `didReceive challenge` → WebKit refuse les certificats invalides, sans bouton « continuer quand même ». Avertissement de site frauduleux activé (`WebViewFactory.swift:47`).
- ⚪ **Pop-ups** : pas de `javaScriptCanOpenWindowsAutomatically` → `window.open` exige un geste. La configuration fournie par WebKit est réutilisée (`Tab.swift:102`) → un pop-up d'une fenêtre privée reste dans le magasin privé.
- ⚪ **Fenêtre privée** : un `WKWebsiteDataStore.nonPersistent()` par fenêtre (`Space.swift:37-38`), vidé au `tearDown` (`BrowserModel.swift:404-409`) ; historique, titres, session, enregistrement de mots de passe et suggestions d'historique sont bien filtrés (`TabWebDelegate.swift:84`, `Tab.swift:197`, `BrowserModel.swift:444`, `PasswordManager.swift:42`, `CommandBar.swift:27`). Les liens d'autres apps n'arrivent jamais dans une fenêtre privée (`AppDelegate.swift:27`).
- ⚪ **Barre d'adresse** : n'affiche que l'hôte (`AddressPill.swift:50-53`) → `https://banque.fr@evil.com` affiche `evil.com`. Les IDN restent en punycode (WebKit remet l'hôte en ASCII dans `webView.url` — SUPPOSÉ, cohérent avec WTF::URL) : pas d'homographe, au prix de la lisibilité. **Ne pas décoder l'IDN** sans reprendre la politique de scripts de Safari.
- ⚪ Hardened Runtime actif, pas d'entitlement dangereux (`allow-jit`, `disable-library-validation`…) (`Config/Void.entitlements`, `project.pbxproj:197,229`). Auto-tests compilés en DEBUG seulement.

---

## 1. Autofill & trousseau

### 1.1 🔴 Remplissage du cadre principal avec le mot de passe d'un autre site (repli sans vérification d'origine) — VÉRIFIÉ
`Features/Passwords/PasswordManager.swift:77-81`
```swift
let result = await webView.voidCall("…fill(u, p)…", arguments: …, in: tab.loginFrame) as? String
if result != "ok" {
    _ = await webView.voidCall("…fill(u, p)…", arguments: …)   // ← cadre principal, sans contrôle
}
```
Combiné à `PasswordManager.swift:36` (un iframe qui a des comptes enregistrés devient `loginFrame`/`loginHost`, même s'il est cross-origin).

**Attaque** : `evil.com` intègre `<iframe src="https://victime.com/login">` (beaucoup de sites n'ont pas `frame-ancestors`). autofill.js de l'iframe annonce `host: victime.com` → icône 🔑 avec les comptes de victime.com. evil.com contient un champ mot de passe masqué au moment du `check()` (`visibility:hidden`), puis le rend visible par un changement d'attribut — le `MutationObserver` d'autofill.js n'écoute que `childList` (`autofill.js:84`), donc le cadre principal ne s'annonce jamais et n'écrase pas `loginHost`. L'utilisateur clique 🔑 → Touch ID « remplir le mot de passe de victime.com » (texte cohérent, il valide). La feuille Touch ID retire le focus clavier de la fenêtre → la page reçoit `blur` et **supprime l'iframe** (ou la renvoie vers `about:blank`). Le premier `voidCall` échoue (cadre disparu ou script absent) → le repli remplit **le cadre principal d'evil.com** avec l'identifiant et le mot de passe de victime.com. evil.com les lit dans son champ.
**Correctif** (≈ 2 h) : supprimer le repli ; ne remplir que dans `loginFrame` et **re-vérifier l'origine juste avant l'injection** (un premier `callAsyncJavaScript` dans ce cadre renvoie `location.origin`, à comparer avec l'origine enregistrée, puis seulement ensuite on remplit) ; prendre l'hôte dans `frame.securityOrigin` (protocole + hôte + port) plutôt que dans `body["host"]` ; ne pas remplir un iframe dont le site diffère de celui du cadre principal (comme Safari).

### 1.2 🟠 Correspondance de domaines trop large, sans liste des suffixes publics — VÉRIFIÉ
`Features/Passwords/KeychainStore.swift:72-77` : `l == h || h.hasSuffix("." + l) || l.hasSuffix("." + h)`.
- Un identifiant enregistré pour `exemple.com` est proposé sur **tout** `*.exemple.com`, y compris des sous-domaines de contenu utilisateur ou repris par un tiers (subdomain takeover, `pages.exemple.com`, hébergeurs multi-clients).
- L'autre sens propose les comptes de `compte.exemple.com` sur `exemple.com`.
Le texte Touch ID affiche `login.host`, ce qui aide un utilisateur attentif, mais la validation se fait par réflexe.
**Correctif** (≈ 45 min) : par défaut, hôte exact (± `www.`) ; les correspondances parent/enfant n'apparaissent que dans une section « Autres comptes de exemple.com » avec une confirmation qui affiche l'hôte d'origine. Sans liste des suffixes publics, ne jamais faire de correspondance sur 2 labels (`co.uk`, `github.io`).

### 1.3 🟠 http et https confondus — VÉRIFIÉ
L'hôte est stocké sans protocole (`KeychainStore.save`, avec `kSecAttrProtocolHTTPS` forcé ligne 42), et `handle`/`fill` ne regardent jamais le protocole du cadre. Un mot de passe enregistré sur `https://site.fr` est proposé et rempli sur `http://site.fr`. **Attaque** : Wi-Fi public, lien vers `http://site.fr` (sans HSTS) → formulaire injecté → 🔑 → Touch ID → le script injecté lit le mot de passe. L'import Chromium (`BrowserImporter.swift:161`) mélange de même les origines http.
**Correctif** (≈ 30 min) : enregistrer le vrai protocole (`kSecAttrProtocol`) depuis `frame.securityOrigin.protocol` ; ne jamais remplir en http un identifiant https (et avertir dans le cas inverse).

### 1.4 🟡 État de connexion périmé après navigation — VÉRIFIÉ
`TabWebDelegate.swift:73-80` : `didCommit` vide `loginAccounts` mais **pas** `loginHost` ni `loginFrame` ; `PasswordManager.swift:36` garde alors un `loginFrame` d'une page précédente tant qu'un nouveau cadre principal ne s'est pas annoncé. Aujourd'hui l'icône 🔑 disparaît (comptes vides), ce qui limite le risque, mais c'est la condition nécessaire de 1.1 : à remettre à `nil` au commit (5 min).

### 1.5 🟡 Délai de grâce Touch ID global de 60 s — VÉRIFIÉ
`PasswordManager.swift:11` : après une authentification (par exemple pour afficher un mot de passe dans les Réglages), n'importe quel remplissage sur n'importe quel site passe sans Touch ID pendant 60 s. **Correctif** : grâce limitée au même hôte, ou supprimée pour le remplissage web (10 min).

### 1.6 🟡 Copie du mot de passe dans le presse-papiers en clair et durable — VÉRIFIÉ
`Settings/SettingsView.swift:430-432` : `setString` sur le presse-papiers général, sans type `org.nspasteboard.ConcealedType`/`TransientType` et sans effacement automatique → historique des gestionnaires de presse-papiers et Presse-papiers universel (iPhone). **Correctif** : types « concealed » et effacement après 60–90 s si le contenu n'a pas changé (`changeCount`) (20 min).

### 1.7 🟡 Invite « Enregistrer le mot de passe ? » déclenchable par la page — VÉRIFIÉ
`autofill.js:48-53` capture sur des `click` non vérifiés (`isTrusted` absent) : une page (ou un iframe publicitaire) peut provoquer à volonté l'invite pour son propre hôte. Pas de fuite, mais du spam et de l'hameçonnage de confiance. Ajouter `if (!e.isTrusted) return;` (5 min).

---

## 2. Barre d'adresse et usurpation

### 2.1 🔴 L'adresse affichée suit l'URL *provisoire* : usurpation par navigation qui n'aboutit jamais — code VÉRIFIÉ, comportement WebKit SUPPOSÉ
`Browser/Tab.swift:200-204` : `tab.url` suit le KVO de `webView.url` ; `AddressPill.swift:40,50-53` en tire l'hôte et le cadenas. Or `WKWebView.url` renvoie l'URL **active**, qui devient l'URL provisoire dès le début d'une navigation, y compris lancée par la page (`PageLoadState::activeURL`).
**Attaque** : `evil.com` affiche une copie de la page de connexion de la banque, puis exécute `location = "https://banque.fr:8443/"` (port filtré : la connexion pend ~75 s) ou toute URL de banque.fr qui ne répond pas. Pendant toute l'attente, Void affiche **`banque.fr` + cadenas** au-dessus du contenu d'evil.com. Safari ne montre l'URL provisoire que pour les navigations tapées par l'utilisateur.
**Vérifier** (5 min) : page locale qui fait `location='https://10.255.255.1/'` → regarder la barre d'adresse.
**Correctif** (≈ 1 h 30) : `Tab.committedURL` mis à jour dans `didCommit`/`didFinish`/`didFailProvisionalNavigation` (+ navigations dans la même page via KVO **seulement** si l'origine reste la même) ; l'affichage (hôte, cadenas, favori, bloqueur par site, Touch ID) utilise `committedURL` ; l'URL provisoire n'est montrée que si la navigation vient de la barre d'adresse.

### 2.2 🟠 Cadenas = simple test du protocole — VÉRIFIÉ
`AddressPill.swift:40` : `scheme == "https"`. Ne tient compte ni de `hasOnlySecureContent` ni de l'état de la navigation (voir 2.1). **Correctif** : cadenas si `committedURL` est https **et** `webView.hasOnlySecureContent` (KVO) ; sinon icône neutre (20 min).

### 2.3 🟠 Mode « onglets masqués » (⌘S) : aucune origine visible — VÉRIFIÉ (choix de design)
`UI/BrowserWindowView.swift:51-96` : la page occupe toute la fenêtre, sans aucun chrome. Une page peut dessiner une fausse barre latérale avec une fausse pastille d'adresse. **Correctif léger** : à chaque changement d'origine validé (commit), afficher 1,5 s une pastille native avec l'hôte ; et toujours afficher l'hôte dans l'invite 🔑 / Touch ID (déjà le cas).

### 2.4 🟡 `core.js` donne `fullscreen` à **tous** les iframes — VÉRIFIÉ
`Resources/Scripts/core.js:26-31` ajoute `allow="…; fullscreen"` + `allowfullscreen` à chaque iframe, publicités comprises. Un iframe publicitaire peut passer en plein écran au premier clic et imiter l'interface de macOS (fausses alertes, faux Touch ID). **Correctif** : n'ajouter `fullscreen` qu'aux iframes des lecteurs vidéo connus (youtube, vimeo, dailymotion, twitch…), ou seulement `picture-in-picture` (15 min).

### 2.5 🟡 Lien du menu contextuel jamais remis à zéro — VÉRIFIÉ
`Web/ScriptMessageRouter.swift:32-33` / `VoidWebView.swift:36-54` : si la page bloque la propagation de `contextmenu` au niveau `window` (avant l'écouteur de Void, posé sur `document`), `contextLinkURL` garde une valeur ancienne (éventuellement d'une page précédente) et les entrées « Ouvrir dans un onglet en arrière-plan / fenêtre privée » ouvrent cette URL-là. Écouter sur `window` en capture et vider `contextLinkURL` à chaque `didCommit` et après chaque menu (10 min).

---

## 3. Ouverture d'URL et schémas

### 3.1 🟠 Schémas externes ouverts sans confirmation, depuis n'importe quel cadre — code VÉRIFIÉ, `linkActivated` sur clic synthétique SUPPOSÉ
`Web/TabWebDelegate.swift:23-26` : tout schéma hors liste (`zoommtg:`, `vscode:`, `smb:`, `afp:`, `x-apple.systempreferences:`, `itms-services:`, `facetime:`…) est passé à `NSWorkspace.shared.open(url)` dès que `navigationType == .linkActivated`, **sans boîte de dialogue**, y compris pour un iframe cross-origin (publicité). WebKit classe aussi `a.click()` scripté en `linkActivated`, ce qui permet une ouverture sans geste réel.
**Attaque** : `smb://attaquant/partage` → le Finder tente de monter un partage distant (fuite d'IP/identifiants, fichiers servis) ; lancement d'apps tierces avec paramètres (URL de réunion, installation d'extension dans un éditeur…).
**Correctif** (≈ 1 h) : fonction pure `ExternalURLPolicy.decide(url:isMainFrame:)` → refus pour `smb/afp/nfs/cifs/ftp/vnc/ssh/telnet/file`, sinon `NSAlert` « Ouvrir « NomDeL'App » ? » (nom via `NSWorkspace.urlForApplication(toOpen:)`) avec le site demandeur ; refus silencieux depuis un sous-cadre cross-origin. `mailto:`/`tel:` peuvent rester sans dialogue.

### 3.2 🟡 `internalSchemes` accepte `file`, `javascript`, `data` — VÉRIFIÉ, risque faible
`TabWebDelegate.swift:14` : les navigations http → `file://` sont bloquées par WebKit (« Not allowed to load local resource ») et les navigations de cadre principal vers `data:` initiées par une page aussi (SUPPOSÉ, comportement WebKit connu). Le menu contextuel peut en revanche ouvrir un `javascript:`/`data:` choisi par la page dans un nouvel onglet (`VoidWebView.swift:67-84`) : filtrer ces URL avant `openTab` (http/https/about uniquement) (10 min).

### 3.3 🟡 Ouverture de fichiers HTML locaux — SUPPOSÉ
`Config/Info.plist` déclare `public.html` ; `openExternal` → `load(URLRequest(file://…))` (`Tab.swift:121/131`). Utiliser `loadFileURL(_:allowingReadAccessTo:)` limité **au fichier** pour borner explicitement l'accès en lecture (15 min).

---

## 4. Téléchargements

### 4.1 🔴 Pas de quarantaine explicite (`com.apple.quarantine`) — code VÉRIFIÉ (aucune occurrence), effet SUPPOSÉ
Aucune trace de quarantaine dans le dépôt (`grep quarantine` : 0 résultat ; pas de `LSFileQuarantineEnabled` dans `Info.plist`). Void n'est pas sandboxé : la quarantaine ne vient pas du sandbox. Le fichier est écrit par le processus réseau de WebKit ; je n'ai **pas** pu confirmer qu'il pose l'attribut pour un `WKDownload` (il le met peut-être seulement à jour s'il existe déjà).
**Vérifier** (2 min) : télécharger un .zip avec Void, puis `xattr -l ~/Downloads/fichier.zip`.
**Si absent** : une app, un `.command`, un `.terminal`, un `.fileloc` ou un paquet téléchargé s'ouvre **sans Gatekeeper ni avertissement** (y compris via « Ouvrir » dans la bibliothèque, `DownloadManager.swift:73-76`). Risque maximal pour un navigateur.
**Correctif** (≈ 45 min, sans regret même si WebKit le fait déjà) : dans `downloadDidFinish` (`DownloadManager.swift:115`), poser `URLResourceValues.quarantineProperties` = `[kLSQuarantineAgentNameKey: "Void", kLSQuarantineTypeKey: kLSQuarantineTypeWebDownload, kLSQuarantineDataURLKey: source, kLSQuarantineOriginURLKey: page]` si l'attribut est absent. Ajouter aussi `LSFileQuarantineEnabled = YES` dans Info.plist. Auto-test : télécharger une URL `data:`/`blob:` vers un dossier temporaire et lire `getxattr("com.apple.quarantine")`.

### 4.2 🟠 Téléchargements sans geste ni confirmation, y compris depuis des iframes — VÉRIFIÉ
`TabWebDelegate.swift:19` (`shouldPerformDownload` : attribut `download`), `:41` (MIME non affichable, **tout cadre**) : un iframe publicitaire peut déposer autant de fichiers qu'il veut dans ~/Téléchargements, sans rien demander. **Correctif** : autoriser sans question les téléchargements du cadre principal consécutifs à un clic ; pour les autres (sous-cadre cross-origin, pas de geste, rafale de plus de 2 en 10 s) → demander « Autoriser les téléchargements depuis site ? » (1 h).

### 4.3 🟡 Nom de fichier — VÉRIFIÉ
`DownloadManager.swift:90` ne retire que `/` et `:`. Retirer aussi les caractères de contrôle et bidi (`U+202E`… : « facture‮fdp.app »), le `.` initial (fichier caché) et limiter la longueur (15 min).

### 4.4 ⚪ Privé : les téléchargements sortent de la liste mais le fichier reste (documenté dans le README). Correct.

---

## 5. Fenêtres privées — fuites

### 5.1 🟠 Favicons des onglets privés via une session réseau partagée — VÉRIFIÉ
`Web/FaviconLoader.swift:7,26` : un seul `URLSession(configuration: .ephemeral)` statique pour **toutes** les fenêtres. Les cookies et le cache « éphémères » vivent en mémoire jusqu'à la fermeture de l'app : un cookie posé par la réponse `/favicon.ico` d'un site visité en privé est renvoyé plus tard depuis une fenêtre normale ou une autre fenêtre privée (liaison entre sessions). La requête sort aussi hors WebKit : **pas de bloqueur**, autre User-Agent (empreinte « Void/… CFNetwork »), pas de proxy/politique du magasin de l'espace. Le cache en mémoire `cache[host]` est bien évité en privé (ligne 32).
**Correctif** (20 min) : configuration sans cookies ni cache (`httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`) et User-Agent de WebKit ; mieux, en privé, ne rien télécharger hors WebKit (lettre à la place de l'icône).

### 5.2 🟡 Extensions et fenêtres privées — VÉRIFIÉ
`hasAccessToPrivateData` est global à l'extension et `WKWebExtensionController(configuration: .default())` est persistant : si « extensions en privé » est activé, une extension peut garder en stockage persistant des données vues en privé. À signaler dans l'interface (5 min de texte).

### 5.3 ⚪ Rien d'autre trouvé : historique, titres, session, suggestions, ⌘⇧T, mots de passe, liste de téléchargements, magasin de données, mode lecture (`.nonPersistent()`, `ReaderMode.swift:112`) — tout est correctement cloisonné (VÉRIFIÉ). `isInspectable = true` (`WebViewFactory.swift:62`) permet d'inspecter une page privée depuis Safari en local : acceptable pour un navigateur de développeur.

---

## 6. Import des autres navigateurs

### 6.1 🟠 Copies de `History` et `Login Data` jamais supprimées — VÉRIFIÉ
`Features/Import/BrowserImporter.swift:220-232` : `openCopy` copie la base (+ `-wal`/`-shm`) dans `$TMPDIR/void-import-UUID/` et ne l'efface jamais. Restent donc sur disque : l'historique complet en clair, et `Login Data` (URLs et identifiants en clair, mots de passe chiffrés dont Void vient de lire la clé). **Correctif** : `defer { try? fm.removeItem(at: dir) }` après la requête (fermer la base avant) (15 min).

### 6.2 🟡 Déchiffrement Safe Storage — VÉRIFIÉ, globalement correct
`ChromiumCrypto` (`:236-283`) : PBKDF2-SHA1/1003/`saltysalt`, AES-128-CBC, IV = 16 espaces, préfixe `v10` : conforme à Chromium macOS. Points mineurs : (a) tout blob sans préfixe `v10` est pris pour du texte en clair (`:262-263`) → un futur `v11` produirait des mots de passe « poubelle » enregistrés : rejeter plutôt qu'accepter ; (b) la requête trousseau ne filtre que `kSecAttrService` (ajouter `kSecAttrAccount` = « Chrome »/« Brave »… pour ne pas prendre un élément homonyme) ; (c) le secret et la clé dérivée restent en mémoire (non effacés) ; (d) conseiller dans l'interface de répondre « Autoriser » (une fois) et non « Toujours autoriser » à l'invite du trousseau. L'import tourne sur le thread principal (gel de l'interface, pas un problème de sécurité).

### 6.3 🟡 Import CSV — `BrowserImporter.swift:200-215`
Le fichier CSV d'export reste en clair là où l'utilisateur l'a mis : proposer « Mettre le CSV à la corbeille » après import (pas de suppression définitive automatique).

---

## 7. Permissions (caméra, micro, géolocalisation)

- ⚪/🟡 **Caméra/micro** : aucune méthode `requestMediaCapturePermissionFor` (`TabWebDelegate.swift:168`) → WebKit affiche sa propre invite à **chaque** demande (SUPPOSÉ : comportement par défaut depuis macOS 12). Sûr, mais : pas de mémoire par site, pas d'indicateur dans l'onglet (seul le point vert de macOS), pas de coupure rapide. À terme : implémenter le délégué (prompt Void avec l'hôte du **cadre principal** + mémoire de session) et une pastille caméra/micro sur l'onglet via `cameraCaptureState` (déjà observé pour la veille, `Tab.swift:187`).
- 🟡 **Géolocalisation** : ni `NSLocationUsageDescription` ni entitlement `com.apple.security.personal-information.location` (Hardened Runtime) → la géolocalisation échoue probablement toujours (SUPPOSÉ). Pas une faille ; à documenter ou à traiter avec une invite propre.
- ⚪ Les entitlements caméra/micro sont nécessaires au Hardened Runtime ; OK.

---

## 8. Bloqueur et règles

- 🟡 **Fenêtre sans blocage au démarrage** : `ContentRules.swift:24-25` libère le premier chargement après 0,5 s même si la liste n'est pas compilée (premier lancement ou changement de version) → premiers traqueurs non bloqués. Et `installAdBlock` retire l'ancienne liste **avant** d'avoir compilé la nouvelle (`:51-52`) → un trou pendant chaque recompilation (bascule par site). Correctif : ajouter la nouvelle liste, puis retirer l'ancienne (10 min).
- 🟡 **Couverture** : ~150 domaines, « tiers » seulement (`AdBlockList.swift`) ; honnête dans le README, mais l'interface ne doit pas laisser croire à une protection contre le pistage comparable à EasyPrivacy. Les requêtes hors WebKit (favicons, 5.1) échappent au bloqueur.
- 🟡 **Règles de masquage** : un seul sélecteur refusé par le compilateur de WebKit fait échouer **toute** la liste `void-hidden` (`ElementHider.swift:63-72` → `ContentRules.swift:85`, erreur seulement dans les logs). Compiler une règle par hôte ou valider chaque sélecteur à l'ajout (20 min).
- ⚪ Liste d'autorisation par site via `ignore-previous-rules` + `if-domain` : correcte.

---

## 9. Extensions web (macOS 15.4+, option)

- 🟠 **Toutes les permissions accordées sans les montrer** : `ExtensionManager.swift:66-71` accorde `requestedPermissions` et **tous** les motifs (`<all_urls>` compris) à l'installation, sans afficher la liste. Une extension peut lire tous les sites, cookies compris selon permissions. Afficher la liste avant installation (1 h).
- 🟠 **Code chargé depuis son emplacement d'origine** : seul le chemin est mémorisé (`:45`) et rechargé à chaque lancement (`:37`) → tout processus capable d'écrire dans ce dossier (Téléchargements…) modifie silencieusement l'extension, qui garde ses permissions. Copier l'extension dans `Application Support/Void/Extensions/<id>` à l'installation (30 min).
- 🟡 `context.isInspectable = true` en Release (`:62`).

---

## 10. Divers

- 🟡 **Vol de focus par sortie de PiP** : `PiPController.swift:50-58` : si la page quitte le PiP elle-même (`document.exitPictureInPicture()`) pendant la lecture, Void sélectionne l'onglet et **s'active au premier plan** (`NSApp.activate(ignoringOtherApps:)`). Avec le PiP automatique, un onglet d'arrière-plan peut donc se remettre devant l'utilisateur au moment qu'il choisit (tabnabbing). Ne revenir à l'onglet que si la sortie suit une interaction avec la fenêtre PiP (SUPPOSÉ : vérifier si l'on peut distinguer ; sinon, ne pas activer l'app).
- 🟡 **Alertes JS en boucle** : feuille modale par alerte (`TabWebDelegate.swift:129-165`), sans case « Empêcher cette page d'afficher d'autres alertes » → DoS de l'onglet.
- 🟡 `developerExtrasEnabled` + `isInspectable` en Release : acceptable pour ce public, à mentionner.

---

## Synthèse par gravité

| # | Constat | Fichier:ligne | Gravité | Statut | Effort |
|---|---|---|---|---|---|
| 1.1 | Repli de remplissage dans le cadre principal (mot de passe d'un autre site) | PasswordManager.swift:77-81, :36 | 🔴 | VÉRIFIÉ | 2 h |
| 2.1 | Barre d'adresse = URL provisoire (usurpation) | Tab.swift:200-204, AddressPill.swift:40-53 | 🔴 | code VÉRIFIÉ / WebKit SUPPOSÉ | 1 h 30 |
| 4.1 | Pas de quarantaine sur les téléchargements | DownloadManager.swift:115-126 | 🔴 si confirmé | SUPPOSÉ (2 min à vérifier) | 45 min |
| 3.1 | Schémas externes sans confirmation, même depuis un iframe | TabWebDelegate.swift:23-26 | 🟠 | VÉRIFIÉ | 1 h |
| 1.2 | Correspondance de domaines sans PSL | KeychainStore.swift:72-77 | 🟠 | VÉRIFIÉ | 45 min |
| 1.3 | http/https confondus | KeychainStore.swift:30-42, PasswordManager.swift | 🟠 | VÉRIFIÉ | 30 min |
| 4.2 | Téléchargements sans geste, depuis des iframes | TabWebDelegate.swift:19,41 | 🟠 | VÉRIFIÉ | 1 h |
| 5.1 | Favicons : session partagée privé/normal, hors bloqueur | FaviconLoader.swift:7,26 | 🟠 | VÉRIFIÉ | 20 min |
| 6.1 | Copies d'import jamais effacées | BrowserImporter.swift:220-232 | 🟠 | VÉRIFIÉ | 15 min |
| 9 | Extensions : permissions muettes, code non copié | ExtensionManager.swift:37-71 | 🟠 | VÉRIFIÉ | 1 h 30 |
| 2.2/2.3 | Cadenas naïf ; aucun hôte visible en mode masqué | AddressPill.swift:40, BrowserWindowView.swift:51-96 | 🟠 | VÉRIFIÉ | 45 min |
| reste | 1.4-1.7, 2.4, 2.5, 3.2, 3.3, 4.3, 6.2, 8, 10 | — | 🟡 | voir sections | 5-20 min chacun |

---

## TOP 5 des chantiers pour cette nuit

Chacun est faisable par un agent seul en quelques heures, sans dépendance externe, et vérifiable par un build plus `-VoidSelfTest features`, avec un cas de test nouveau par chantier. Les auto-tests peuvent simuler des origines avec `loadHTMLString(_:baseURL:)` (`https://a.test`, `https://b.test`) et des iframes `srcdoc`/`about:blank`.

1. **Autofill verrouillé par origine** (1.1 + 1.3 + 1.4 + 1.7) — ~3 h.
   Supprimer le repli vers le cadre principal ; hôte **et protocole** pris dans `frame.securityOrigin` ; vérification `location.origin` dans le cadre juste avant l'injection ; pas de remplissage dans un iframe d'un autre site que le cadre principal ; `loginHost`/`loginFrame` remis à `nil` au commit ; `isTrusted` dans autofill.js. Pour la testabilité, isoler une fonction pure `PasswordManager.canFill(savedHost:savedScheme:frameOrigin:topOrigin:)` et un point d'injection pour le trousseau (faux magasin en DEBUG).
   *Tests* : (a) tableau de cas `canFill` (même hôte ✔, http vs https ✘, iframe d'un autre site ✘, sous-domaine ✘ par défaut) ; (b) page `https://a.test` + iframe, `loginFrame` supprimé avant `fill` → **aucun** champ du cadre principal rempli.

2. **Barre d'adresse sur l'URL validée** (2.1 + 2.2) — ~2 h.
   `Tab.committedURL` (commit / finish / échec de la navigation provisoire / navigations dans la même page de même origine) ; pastille, cadenas (`hasOnlySecureContent`), bloqueur par site, favori et `addressText` s'en servent ; l'URL provisoire n'est montrée que pour une saisie dans la barre.
   *Test* : page `https://a.test` qui exécute `location='https://10.255.255.1/'` → 1 s plus tard, `addressText == "a.test"` et pas de cadenas « b ».

3. **Téléchargements sûrs** (4.1 + 4.2 + 4.3) — ~2 h.
   Quarantaine explicite dans `downloadDidFinish` (+ `LSFileQuarantineEnabled`) ; noms nettoyés (bidi, contrôle, `.` initial) ; téléchargements de sous-cadre cross-origin ou en rafale → confirmation.
   *Tests* : téléchargement d'un `data:` vers un dossier temporaire → `getxattr("com.apple.quarantine")` présent et agent « Void » ; `uniqueDestination("a\u{202E}fdp.app")` nettoyé ; fonction pure `DownloadPolicy.decide(isMainFrame:sameOrigin:recentCount:)`.

4. **Ouverture d'apps externes sous contrôle** (3.1 + 3.2) — ~1 h 30.
   `ExternalURLPolicy` : liste de refus (`smb`, `afp`, `nfs`, `cifs`, `ftp`, `vnc`, `ssh`, `telnet`, `file`), refus depuis un iframe cross-origin, `NSAlert` avec le nom de l'app pour le reste (sauf `mailto`/`tel`) ; filtrage http/https/about des URL du menu contextuel.
   *Tests* : tableau de cas sur la fonction pure ; en DEBUG, compteur des `NSWorkspace.open` à 0 après un `a.click()` scripté vers `smb://…` dans un iframe.

5. **Hygiène vie privée groupée** (5.1 + 6.1 + 1.6 + 2.4 + 8 « échange de liste ») — ~1 h 30.
   Session des favicons sans cookies ni cache et avec l'UA de WebKit (rien hors WebKit en privé) ; suppression du dossier temporaire d'import ; presse-papiers « concealed » avec effacement à 90 s ; `fullscreen` réservé aux iframes des lecteurs vidéo ; nouvelle liste de blocage ajoutée **avant** de retirer l'ancienne.
   *Tests* : `FaviconLoader.session.configuration.httpCookieStorage == nil` ; après `openCopy` suivi d'une fermeture, le dossier `void-import-*` n'existe plus ; iframe publicitaire inséré → `allow` sans `fullscreen`, iframe youtube → avec.

À planifier ensuite (pas cette nuit) : écran de permissions des extensions et copie de leur code (§9), invite caméra/micro propre avec indicateur dans l'onglet (§7), pastille d'origine en mode onglets masqués (§2.3).
