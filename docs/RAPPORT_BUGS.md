# Rapport d'analyse des bugs — Void 0.1

Branche analysée : `gestionnaires-apps-historique` (commit `b73d6a2`), 30 septembre 2026.

## Méthode et limites

- Lecture intégrale du code Swift et JavaScript (≈ 12 700 lignes), hors auto-tests (`SelfTest/`, compilés en Debug seulement).
- Compilation Debug (`xcodebuild … -configuration Debug build`) : **réussie, aucun avertissement du compilateur**.
- Aucun bug n'a été reproduit dans l'app en marche, et les auto-tests n'ont pas été relancés. Chaque point indique donc son niveau de certitude :
  - **Confirmé (lecture)** : le chemin de code est sans ambiguïté.
  - **Probable** : dépend d'un comportement de WebKit ou de macOS à vérifier.

Gravité : 🔴 élevée (perte de données, sécurité, comportement visible et fréquent) · 🟠 moyenne · 🟡 faible (cas limite, finition).

## Corrections (branche `corrections-rapport-bugs`)

Tous les points sont corrigés, sauf le troisième volet du point 22 (correspondance des identifiants entre sous-domaines), laissé tel quel : le resserrer demande la liste des suffixes publics et un changement du menu de remplissage.

Vérification : compilation Debug sans avertissement, et auto-tests `session, onglets, telechargements, adresse, stabilite, historique, mots-de-passe, disposition, extensions, store, barre-commande, plein-ecran, lecteurs, glisser, lancement-extensions, popups-installes` et la nouvelle section **`corrections`** (12 vérifications : points 1, 4, 5, 9, 10, 13, 16, 17, 21) : **83 ✅ / 0 ❌** (en trois passages). Le test « espace supprimé, seul espace d'une fenêtre ⌘N » a été adapté au point 21 (les fenêtres ⌘N suivent désormais les espaces de la fenêtre principale). Les dialogues de confirmation (points 3, 6, 7) et le reverrouillage des Réglages (22) sont vérifiés à la compilation et à la relecture seulement.

Écarts par rapport aux solutions proposées plus bas :
- Point 8 : le cache des comptes du trousseau est protégé par un verrou (l'import écrit hors du fil principal).
- Point 10 : pas de confirmation fondée sur `hasUserInput` (elle aurait gêné chaque onglet de messagerie) ; seul `beforeunload` est respecté, via `_tryClose`, avec fermeture forcée après 2 s si la page ne répond pas.
- Point 18 : noms sensibles (carte, CVV, IBAN, mot de passe, jeton…) exclus où qu'ils apparaissent, recherches et codes exclus seulement en mot entier.
- Point 23 : la lecture automatique avec le son reste autorisée par défaut, avec un réglage pour la bloquer.

## Synthèse

| # | Gravité | Sujet | Fichier(s) | Certitude |
|---|---|---|---|---|
| 1 | 🔴 | Fermer l'onglet actif d'un autre espace fait basculer dans cet espace (suppression d'espace comprise) | `BrowserModel.swift` | Confirmé |
| 2 | 🔴 | Les données d'un espace supprimé restent probablement sur le disque | `BrowserModel.swift` | Probable |
| 3 | 🔴 | Actions destructrices sans confirmation | `SidebarView`, `LibraryView`, `SettingsView` | Confirmé |
| 4 | 🔴 | Extension piégée : liens symboliques → écriture hors du dossier | `ExtensionManager`, `ChromeExtensions` | Confirmé |
| 5 | 🟠 | Mode « Automatique » : une app de mots de passe installée coupe tout gestionnaire dans Void | `PasswordManager.swift` | Confirmé |
| 6 | 🟠 | Permissions d'extension accordées sans être montrées, mises à jour comprises | `ExtensionManager.swift` | Confirmé |
| 7 | 🟠 | Téléchargements déclenchés par une page sans aucune confirmation | `TabWebDelegate`, `DownloadManager` | Confirmé |
| 8 | 🟠 | Travail lourd sur le fil principal (lancement, import) | `ExtensionManager`, `SettingsView` | Confirmé |
| 9 | 🟠 | Sélectionner un onglet déjà fermé crée une page invisible qui peut jouer du son | `BrowserModel.swift` | Confirmé |
| 10 | 🟠 | Fermer un onglet ne prévient pas de la perte d'un texte saisi | `BrowserModel`, `Tab` | Confirmé |
| 11 | 🟡 | Favicon de la page précédente appliqué après une navigation | `FaviconLoader.swift` | Confirmé |
| 12 | 🟡 | État périmé après une mise en veille (Précédent actif, cadenas…) | `Tab.swift` | Confirmé |
| 13 | 🟡 | ⌘W sur un onglet épinglé laisse une page vide au lieu d'un onglet voisin | `BrowserModel.swift` | Confirmé |
| 14 | 🟡 | Bloqueur activé/désactivé : rechargement trop tôt, parfois du mauvais onglet | `BrowserModel+Actions.swift` | Confirmé |
| 15 | 🟡 | Listes de règles compilées jamais supprimées | `ContentRules.swift` | Confirmé |
| 16 | 🟡 | `session.json` réécrit en entier, favicons inclus, à chaque changement | `BrowserModel`, `StateStore` | Confirmé |
| 17 | 🟡 | Barre d'adresse : une adresse e-mail est ouverte comme un site | `URLResolver.swift` | Confirmé |
| 18 | 🟡 | Formulaires : codes postaux et champs « shipping… » jamais retenus | `formfill.js` | Confirmé |
| 19 | 🟡 | ⌘G envoyé à toutes les fenêtres | `Overlays.swift` | Confirmé |
| 20 | 🟡 | Bibliothèque / « Revoir… » sans effet quand la fenêtre principale est fermée | `LibraryView`, `SettingsView` | Confirmé |
| 21 | 🟡 | Fenêtres ⌘N : espaces non synchronisés, onglets perdus au quit | `BrowserModel.swift` | Confirmé |
| 22 | 🟡 | Mots de passe : délai de grâce Touch ID partagé, mots de passe affichés sans reverrouillage | `PasswordManager`, `SettingsView` | Confirmé |
| 23 | 🟡 | Divers (import, masquage d'éléments, raccourcis, libellés…) | plusieurs | Confirmé |

**Ordre de correction conseillé** : 3 et 1 (simples, visibles, risque de perte de données), puis 4 et 2 (sécurité, confidentialité), 5 (régression de cette branche), 9, 6, 7, 8, et enfin le reste.

---

## 🔴 1. Fermer l'onglet actif d'un autre espace fait basculer dans cet espace

**Où** : `Void/Browser/BrowserModel.swift:181-194` (`select`), `:231-247` (`selectNeighbor`), `:380-399` (`deleteSpace`).

**Symptômes**
- **Supprimer un espace qui n'est pas l'espace affiché.** `deleteSpace` ferme ses onglets un par un. Fermer l'onglet sélectionné appelle `selectNeighbor`, qui appelle `select(voisin)`. Or `select` fait de l'espace du voisin l'espace courant et crée sa vue web (`ensureWebView`). Résultat :
  - chaque onglet de l'espace condamné est réveillé et lance une requête réseau, avec les cookies de l'espace, juste avant d'être fermé ;
  - PiP automatique et évènements d'extension (`tabActivated`) partent pour des onglets en cours de destruction ;
  - comme l'espace courant est devenu l'espace supprimé, la ligne 394 bascule ensuite sur le **premier** espace, et non sur celui où se trouvait l'utilisateur.
- **Cas plus courant.** L'onglet sélectionné d'un espace en arrière-plan est fermé par une extension (`chrome.tabs.remove`), par la page elle-même (`window.close()` d'une fenêtre OAuth) ou par « Déplacer vers ». L'utilisateur est alors emmené de force dans cet espace.

**Cause** : `selectNeighbor` passe par `select()`, qui sert à *montrer* un onglet, alors qu'il suffit ici de mettre à jour la sélection mémorisée de l'espace.

**Correction**
```swift
// BrowserModel.swift
func close(_ tab: Tab, force: Bool = false, reselect: Bool = true) {
    …
    if reselect, space.selectedTabID == tab.id { selectNeighbor(of: tab, in: space) }
    …
}

private func selectNeighbor(of tab: Tab, in space: Space) {
    let next = neighbor(of: tab, in: space)          // voir aussi le point 13
    guard space.id == currentSpaceID else {
        // Espace en arrière-plan : on change seulement sa sélection, sans l'afficher ni réveiller l'onglet.
        space.selectedTabID = next?.id
        return
    }
    if let next { select(next); return }
    let previous = space.selectedTab
    withAnimation(Theme.spring) { space.selectedTabID = nil }
    PiPController.shared.selectionChanged(from: previous, to: nil)
}

func deleteSpace(_ space: Space) {
    …
    // Changer d'espace AVANT de fermer, et sans resélection : aucun onglet condamné n'est réveillé.
    if space.id == currentSpaceID, let other = spaces.first(where: { $0.id != space.id }) { switchSpace(to: other) }
    for tab in space.allTabs { close(tab, force: true, reselect: false) }
    …
}
```
Même principe pour les fenêtres secondaires, dans la boucle `for tab in mirror.allTabs { other.close(tab, force: true) }`.

**Test à ajouter** : deux espaces A (affiché) et B avec 3 onglets. Supprimer B → l'espace courant reste A et aucune vue web n'est créée pour les onglets de B.

---

## 🔴 2. Les données d'un espace supprimé restent probablement sur le disque

**Où** : `Void/Browser/BrowserModel.swift:396-397`.

**Symptôme** : l'utilisateur supprime un espace (« Supprimer l'espace et ses données : cookies, sessions, cache ») et s'attend à être déconnecté de ses sites. `WKWebsiteDataStore.remove(forIdentifier:)` échoue quand un magasin portant cet identifiant est encore utilisé, et **l'erreur est ignorée** (`{ _ in }`). Or, au moment de l'appel :
- l'objet `space` garde son `_dataStore` jusqu'à la fin de la fonction, et les vues SwiftUI peuvent encore le retenir ;
- les vues web qu'on vient d'endormir sont libérées de façon asynchrone ;
- les copies miroir des fenêtres ⌘N ont leur propre référence au même magasin.

Les cookies et le stockage de l'espace supprimé resteraient alors sur le disque indéfiniment. Aucun auto-test ne vérifie la suppression effective (`FeatureSelfTest.swift:365` supprime l'espace sans contrôler le disque).

**Correction**
1. Effacer d'abord le *contenu* du magasin, ce qui fonctionne même quand il est encore utilisé :
   ```swift
   space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
   ```
2. Tenter la suppression du dossier, **journaliser l'erreur**, et en cas d'échec mémoriser l'identifiant (UserDefaults, `pendingStoreRemovals`).
3. Au lancement, avant la création de tout magasin (dans `applicationWillFinishLaunching` : `Space.dataStore` est paresseux), retenter la suppression des identifiants en attente. Optionnel : supprimer aussi les magasins orphelins, c'est-à-dire ceux que liste `WKWebsiteDataStore.fetchAllDataStoreIdentifiers` et qui ne figurent pas dans `session.json`.
4. Ajouter un auto-test : après suppression puis relance, `fetchAllDataStoreIdentifiers` ne contient plus l'identifiant.

---

## 🔴 3. Actions destructrices sans confirmation

| Action | Où | Conséquence |
|---|---|---|
| « Supprimer l'espace » (clic droit sur l'icône d'espace) | `Void/UI/SidebarView.swift:161` | Onglets, onglets épinglés et **tous les cookies et sessions** de l'espace supprimés en un clic. Les Réglages, eux, demandent confirmation (`SettingsView.swift:184`). |
| « Effacer l'historique… » | `Void/Features/Library/LibraryView.swift:69-72` | Tout l'historique effacé. Les points de suspension annoncent une question qui ne vient pas. |
| « Effacer cookies, caches et historique… » | `Void/Settings/SettingsView.swift:348-355` | Déconnexion de tous les sites dans tous les espaces, sans retour possible. |
| « Retirer » une extension | `Void/Settings/SettingsView.swift:728` | Réglages et données de l'extension supprimés (le bouton du Chrome Web Store, lui, demande confirmation). |
| « Supprimer » un mot de passe | `Void/Settings/SettingsView.swift:429-432` | Suppression immédiate de l'élément du trousseau. |

**Correction** : un `confirmationDialog` sur chacune, avec un bouton `role: .destructive` qui nomme l'objet (« Supprimer l'espace « Travail » et ses données »). Pour l'espace, réutiliser le dialogue de `SpacesSection` : le déplacer dans un modificateur partagé, ou passer par un `pendingDeletion` porté par `BrowserModel`.

Au passage, « Effacer cookies, caches et historique » laisse plusieurs traces : la liste « Rouvrir l'onglet fermé » (`closedTabs`), le cache mémoire des favicons (`FaviconLoader.cache`), les données de formulaires (`FormAutofill`) et la liste des téléchargements. Il faut soit les effacer aussi, soit le dire dans le libellé.

---

## 🔴 4. Extension piégée : liens symboliques → écriture hors du dossier de l'extension

**Où** : `Void/Features/Extensions/ChromeExtensions.swift:87-97` (`unzip` avec `ditto`), `Void/Features/Extensions/ExtensionManager.swift:128-131, 157` (copies), `:263-336` (`addShims`).

**Symptôme** : `ditto -x -k` recrée les liens symboliques contenus dans une archive, et `copyItem` les conserve. Une extension (.crx/.zip choisi par l'utilisateur, ou paquet du Store) peut donc contenir `void-shim.js`, `void-blank.html` ou `void-background.js` sous forme de lien vers un fichier de l'utilisateur. `addShims` écrit ces trois fichiers en **écriture non atomique** (`Data.write(to:)`, lignes 270, 272 et 285), ce qui **suit le lien** : le fichier cible est écrasé. Void n'est pas sandboxé (`Config/Void.entitlements`), donc n'importe quel fichier du compte est exposé. Les contrôles `standardizedFileURL.path.hasPrefix(...)` ne résolvent pas les liens et ne protègent pas. Un lien symbolique pourrait aussi exposer un fichier local comme ressource de l'extension (à vérifier côté WebKit).

**Correction**
```swift
// ChromeExtensions.swift — après unzip / copyItem, avant tout chargement
static func rejectSymbolicLinks(in folder: URL) throws {
    let keys: [URLResourceKey] = [.isSymbolicLinkKey]
    let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [])
    while let url = e?.nextObject() as? URL {
        if try url.resourceValues(forKeys: Set(keys)).isSymbolicLink == true {
            throw Failure.unzip   // ou un cas dédié : « L'extension contient des liens symboliques »
        }
    }
}
```
- L'appeler dans `install(from:)`, `installFromWebStore`, `importExtension`, **et** en tête de `addShims` pour les installations existantes (en cas de lien, ne rien écrire).
- Passer toutes les écritures d'`addShims` en `.atomic` (un renommage remplace le lien au lieu de le suivre).
- Comparer les chemins après `resolvingSymlinksInPath()`.

---

## 🟠 5. Mode « Automatique » : une app de mots de passe installée coupe tout gestionnaire dans Void (nouveau sur cette branche)

**Où** : `Void/Features/Passwords/PasswordManager.swift:32-38` (`isActive`), `:41`, `:87`.

**Symptôme** : en mode Automatique (réglage par défaut), `isActive` vaut `otherManagerName == nil`. Or `otherManagerName` inclut `installedApp`, c'est-à-dire n'importe laquelle des 12 apps connues présente sur le Mac, **même sans son extension dans Void et même inutilisée** (un vieux LastPass ou MacPass resté dans /Applications suffit). Void cesse alors de proposer l'enregistrement et le remplissage, alors qu'aucune extension ne prend le relais : **plus aucun gestionnaire de mots de passe dans Void**. Seule la légende des Réglages l'explique.

S'y ajoute un faux positif : `managerExtensionName` considère comme gestionnaire toute extension dont la *description* contient « password » ou « mot de passe » (générateur de mots de passe, vérificateur de fuites…). Cela désactive aussi le remplissage des formulaires (`FormAutofill.isEnabled`).

**Correction**
```swift
var isActive: Bool {
    switch AppSettings.shared.passwordManager {
    case .void: true
    case .other: false
    // Ne s'effacer que devant une extension qui remplit réellement dans Void.
    case .automatic: managerExtensionName == nil
    }
}
```
- Garder la suggestion « Ajouter l'extension X » dans les Réglages quand seule l'app est présente (`missingExtensionID`). Elle pourrait aussi apparaître dans la barre d'enregistrement du mot de passe.
- Restreindre l'heuristique aux identifiants connus (`knownApps[].extensionID` + `passwordManagerIDs`) et au **nom** de l'extension, pas à sa description.
- `installedApp` est un `lazy var`, calculé une seule fois par lancement : ajouter une app en cours de session n'est pas pris en compte. C'est documenté, mais à garder en tête.

---

## 🟠 6. Permissions d'extension accordées sans être montrées, mises à jour comprises

**Où** : `Void/Features/Extensions/ExtensionManager.swift:395-401`.

**Symptôme** : à chaque chargement, **toutes** les permissions et tous les motifs d'URL du manifeste (`<all_urls>` compris) sont accordés explicitement. L'utilisateur ne voit jamais la liste, ni à l'installation (bouton « Ajouter à Void » du Store, lien collé), ni lors d'une réinstallation qui apporte une version demandant **plus** de droits. Chrome, lui, affiche les droits à l'installation et désactive une extension dont une mise à jour élargit les permissions.

**Correction**
- Avant `add(...)`, présenter une feuille qui résume `ext.requestedPermissions` et `ext.allRequestedMatchPatterns` (« Lire et modifier les données de tous les sites », etc.), avec Autoriser / Annuler.
- Mémoriser dans `InstalledExtension` l'ensemble accordé. Au chargement, n'accorder que cet ensemble. S'il manque des droits (mise à jour), demander de nouveau avant de charger.

---

## 🟠 7. Téléchargements déclenchés par une page sans aucune confirmation

**Où** : `Void/Web/TabWebDelegate.swift:20, 48-57`, `Void/Features/Library/DownloadManager.swift:153-162`.

**Symptôme** : tout `Content-Disposition: attachment`, tout lien `download` ou tout type non affichable part directement dans ~/Downloads, sans limite. Une page peut déclencher des dizaines de téléchargements en boucle (`a.click()` dans un intervalle), donc sans geste de l'utilisateur. La quarantaine protège l'ouverture, pas l'encombrement ni le dépôt discret de fichiers. Safari demande « Autoriser les téléchargements sur ce site ? » la première fois.

**Correction** : une permission par site (clé = hôte normalisé, en mémoire pour les fenêtres privées), demandée par une feuille au premier téléchargement d'un site. Au minimum, une limite (par exemple 3 téléchargements en 10 s par onglet, les suivants annulés avec un toast).

---

## 🟠 8. Travail lourd sur le fil principal

**Où et symptômes**
- `Void/Features/Extensions/ExtensionManager.swift:382` : `load` (`@MainActor`) appelle `addShims` **de façon synchrone à chaque lancement**. La fonction réécrit le manifeste et toutes les pages HTML, puis parcourt **tous** les fichiers .js avec deux expressions régulières (`prependShim`). Une extension volumineuse (Proton Pass : plusieurs Mo de JS minifié) peut figer l'interface quelques secondes au démarrage.
- `Void/Settings/SettingsView.swift:544-549` : `runImport` exécute `BrowserImporter.run` de façon synchrone. Copie des bases, 5 000 lignes d'historique, déchiffrement et écriture de chaque mot de passe dans le trousseau : l'interface est figée, et le libellé « Import… » ne s'affiche jamais puisque `working` repasse à `false` avant le rendu suivant.
- `Void/Features/Passwords/PasswordManager.swift:112` : chaque formulaire de connexion détecté interroge **tout** le trousseau (`SecItemCopyMatching` + `kSecMatchLimitAll`) sur le fil principal.

**Correction**
- `addShims` : le lancer dans un `Task.detached`, qui ne touche que des fichiers. Ne le relancer que si un marqueur (`void-shim.version`, contenant la version du shim et la version de l'extension) a changé.
- Import : `working = true`, puis `Task.detached { … }` pour la lecture des fichiers et le déchiffrement, et retour sur le `MainActor` pour `BookmarkStore` et `HistoryStore`, qui sont `@MainActor`. Les appels au trousseau peuvent rester hors du fil principal.
- Mots de passe : un cache de la liste des comptes (hôte → comptes), invalidé à `save`, `delete` et à l'import.

---

## 🟠 9. Sélectionner un onglet déjà fermé crée une page invisible qui peut jouer du son

**Où** : `Void/Browser/BrowserModel.swift:181-194` (`select`), `:196-229` (`close` ne remet pas `tab.space` à nil), `Void/UI/CommandBar.swift:195`.

**Symptôme** : les suggestions de la barre d'adresse sont calculées à la frappe. Si un onglet proposé (« Aller à l'onglet ») est fermé entre-temps (par la page, une extension ou un téléchargement), le choisir appelle `select(onglet fermé)`. `tab.space` est toujours renseigné, donc `select` définit `selectedTabID` et appelle `ensureWebView()`. Une vue web est créée pour un onglet qui n'est plus dans aucune liste : elle charge la page, peut jouer une vidéo ou du son, et n'est **ni visible ni fermable**. L'espace n'affiche plus rien, car `selectedTab` vaut `nil`.

**Correction**
```swift
func select(_ tab: Tab) {
    guard !tab.isClosed, let space = tab.space, space.allTabs.contains(where: { $0 === tab }) else { return }
    …
}
```
Et dans `close`, après `tab.isClosed = true` : `tab.space = nil`. Vérifier au préalable que plus rien n'utilise `tab.browser` après la fermeture, notamment la Task PiP de la ligne 205.

---

## 🟠 10. Fermer un onglet ne prévient pas de la perte d'un texte saisi

**Où** : `Void/Browser/BrowserModel.swift:196-229`, `Void/Browser/Tab.swift:152-182`.

**Symptôme** : ⌘W, la croix ou « Fermer la fenêtre » détruisent la vue web (`stopLoading`, `removeFromSuperview`) sans passer par `beforeunload`. Aucun « Quitter la page ? » n'apparaît, même dans un formulaire ou un éditeur (webmail, CMS) où le site le demande. Void sait pourtant qu'un texte a été saisi (`tab.hasUserInput`, via activity.js).

**Correction**
- Simple : si `tab.hasUserInput`, demander confirmation (« Cet onglet contient du texte que vous avez saisi. Le fermer ? »).
- Complet : appeler le SPI `_tryClose` de `WKWebView` (qui exécute `beforeunload`), et implémenter `_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:` dans `TabWebDelegate`, protégé par `responds(to:)` comme les autres SPI de `WebKitSPI`.

---

## 🟡 11. Favicon de la page précédente appliqué après une navigation

**Où** : `Void/Web/FaviconLoader.swift:16-38`.

**Symptôme** : le téléchargement du favicon du site A est asynchrone et peut prendre plusieurs secondes. Si l'onglet navigue entre-temps vers le site B, et que le favicon de B est déjà en cache (réglé tout de suite), le résultat tardif de A **écrase** celui de B. Le mauvais favicon est ensuite sauvegardé dans la session.

**Correction** : avant `tab.setFavicon(...)`, vérifier que la page n'a pas changé :
```swift
guard tab.webView?.url?.host() == host else { return }
```

---

## 🟡 12. État périmé après une mise en veille

**Où** : `Void/Browser/Tab.swift:152-182` (`sleep`), `:239-290` (observations KVO en `[.new]`).

**Symptôme** : `sleep()` ne remet pas à zéro `canGoBack`, `canGoForward`, `hasOnlySecureContent`, `loadError` et `isInElementFullscreen`. Comme les observations KVO n'ont pas l'option `.initial`, un onglet réveillé sans historique (un onglet épinglé mis en veille par ⌘W, par exemple) garde un bouton « Précédent » actif qui ne fait rien, jusqu'au prochain changement.

**Correction** : remettre ces propriétés à leur valeur par défaut dans `sleep()`, et utiliser `options: [.initial, .new]` pour `canGoBack`, `canGoForward` et `hasOnlySecureContent`.

---

## 🟡 13. ⌘W sur un onglet épinglé laisse une page vide

**Où** : `Void/Browser/BrowserModel.swift:231-247`.

**Symptôme** : `selectNeighbor` ne cherche un voisin que dans `space.tabs`. Un onglet épinglé n'y figure pas : sans autre épinglé éveillé, la sélection passe à `nil` et la page « Rien ici » s'affiche, même s'il reste des onglets ordinaires.

**Correction** : quand l'onglet fermé est épinglé, choisir d'abord le premier onglet ordinaire, puis un épinglé éveillé. Cette logique trouve sa place dans la fonction `neighbor(of:in:)` du point 1.

---

## 🟡 14. Bloqueur activé ou désactivé : rechargement trop tôt, parfois du mauvais onglet

**Où** : `Void/Browser/BrowserModel+Actions.swift:83-89`, `Void/Features/AdBlock/ContentRules.swift:47-49`.

**Symptôme** : le rechargement part au bout de 0,3 s fixes. La liste de règles est recompilée en asynchrone (nouvel identifiant, donc compilation), et le rechargement peut précéder son installation : la page revient avec les **anciennes** règles. `self.reload()` recharge en outre l'onglet sélectionné *à ce moment-là*, qui peut ne plus être le bon.

**Correction** : `ContentRules.reload(completion:)` (ou une version `async`), puis recharger l'onglet capturé au départ :
```swift
let tab = selectedTab
Task { await ContentRules.shared.installAdBlockNow(); tab?.webView?.reload() }
```

---

## 🟡 15. Listes de règles compilées jamais supprimées

**Où** : `Void/Features/AdBlock/ContentRules.swift:91-110`.

**Symptôme** : chaque liste blanche différente produit une liste compilée `void-adblock-4-<hash>`, et chaque ensemble d'éléments masqués une `void-hidden-<hash>`. WebKit les garde dans `~/Library/WebKit/…/ContentRuleLists` et rien ne les supprime : le dossier grossit à chaque bascule du bloqueur sur un site.

**Correction** : dans `replace`, après avoir retiré l'ancienne liste, appeler `store.removeContentRuleList(forIdentifier: old.identifier)`. Au démarrage, supprimer via `store.availableIdentifiers` tout identifiant `void-*` qui n'est pas l'actuel.

---

## 🟡 16. `session.json` réécrit en entier, favicons inclus, à chaque changement

**Où** : `Void/Browser/BrowserModel.swift:477-496`, `Void/Browser/StateStore.swift:114-117`.

**Symptôme** : chaque chargement de page, changement d'URL ou favicon déclenche, une seconde plus tard, l'encodage et l'écriture atomique de toute la session. Chaque onglet y porte son favicon en PNG (encodé en base64 dans le JSON). Avec quelques dizaines d'onglets, cela fait des centaines de Ko réécrits à chaque navigation, et le fichier est en plus copié à chaque lancement (`session.backup.json`).

**Correction** : stocker les favicons à part (cache par hôte dans `Application Support/Void/Favicons/`) et ne garder que l'hôte dans `SavedTab`. Allonger le délai d'enregistrement (3 à 5 s), en conservant `saveNow()` à la fermeture.

---

## 🟡 17. Barre d'adresse : une adresse e-mail est ouverte comme un site

**Où** : `Void/Browser/URLResolver.swift:13-25`.

**Symptômes**
- Taper `jean@exemple.fr` ouvre `https://jean@exemple.fr`, c'est-à-dire le site `exemple.fr` avec `jean` comme identifiant, au lieu de lancer une recherche.
- `localhostfoo` (ou `localhost.fr`) est ouvert en `http://`.
- Beaucoup de noms de fichiers (`vue.js`, `notes.md`) passent pour des domaines. C'est un compromis connu, sans gravité.

**Correction**
```swift
if !lower.contains("://"), let at = lower.firstIndex(of: "@"),
   lower[..<at].allSatisfy({ $0 != "/" }) { return nil }        // e-mail → recherche
if lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/") { … }
```

---

## 🟡 18. Formulaires : codes postaux et champs « shipping… » jamais retenus

**Où** : `Void/Resources/Scripts/formfill.js:11`.

**Symptôme** : `SKIP_KEY = /otp|captcha|token|search|query|^q$|code|pin|cvv|card/` teste des **sous-chaînes**. `postal-code` et `zip_code` contiennent « code », `shipping_city` et `shipping_address` contiennent « pin » : les codes postaux et la plupart des adresses de livraison ne sont jamais mémorisés.

**Correction** : tester des mots entiers, et laisser passer les clés d'adresse connues :
```js
const SKIP_KEY = /(^|[-_\s.])(otp|captcha|token|search|query|q|code|pin|cvv|cvc|card)([-_\s.]|$)/;
const ALWAYS = /^(postal-code|zip|zip[-_]?code|postcode)$/;
if (!ALWAYS.test(key) && (key.length < 2 || key.length > 60 || SKIP_KEY.test(key))) return null;
```

---

## 🟡 19. ⌘G envoyé à toutes les fenêtres

**Où** : `Void/App/VoidCommands.swift:45-48`, `Void/UI/Overlays.swift:151-153`.

**Symptôme** : « Occurrence suivante » publie une notification globale. Toutes les barres de recherche ouvertes, dans toutes les fenêtres, relancent leur recherche. Et sans barre ouverte, ⌘G ne fait rien (Safari reprend la dernière recherche).

**Correction** : publier avec `object: browser` (la fenêtre active) et filtrer dans `onReceive`, ou mieux, mémoriser `lastFindText` dans `BrowserModel` et appeler `browser.find(lastFindText, backwards:)` directement depuis la commande.

---

## 🟡 20. Bibliothèque et « Revoir… » sans effet quand la fenêtre principale est fermée

**Où** : `Void/Features/Library/LibraryView.swift:43-46`, `Void/Settings/SettingsView.swift:52-56`.

**Symptôme** : un double-clic sur une entrée d'historique ou un favori ouvre l'onglet dans la fenêtre **principale**, même si l'utilisateur travaille dans une fenêtre ⌘N. Si la fenêtre principale est fermée, l'onglet s'ajoute à une fenêtre invisible et rien ne s'affiche. Même chose pour « Revoir… » la personnalisation.

**Correction** : `BrowserWindows.shared.normalTarget.openExternal(url)`, qui rouvre déjà la fenêtre principale si besoin. Pour l'accueil : `openWindowAction?(WindowID.main)` avant de régler `onboardingStep`.

---

## 🟡 21. Fenêtres ⌘N : espaces non synchronisés, onglets perdus au quit

**Où** : `Void/Browser/BrowserModel.swift:99-106`, `:474-475`.

**Symptômes**
- Une fenêtre ⌘N reçoit une *copie* des espaces. Renommer un espace, changer son icône ou en créer un dans la fenêtre principale ne s'y reflète pas.
- Les onglets des fenêtres ⌘N ne sont jamais sauvegardés : quitter Void les perd sans avertissement. C'est documenté, mais surprenant.

**Correction** : faire observer le nom et l'icône par les copies (ou partager un modèle `SpaceInfo` observable par identifiant), et répercuter `addSpace`. Au quit, avec des fenêtres ⌘N ouvertes : proposer de fusionner leurs onglets dans la fenêtre principale, ou au moins prévenir.

---

## 🟡 22. Mots de passe : délai de grâce Touch ID partagé, mots de passe affichés sans reverrouillage

**Où** : `Void/Features/Passwords/PasswordManager.swift:10-11`, `Void/Settings/SettingsView.swift:364-367`, `Void/Features/Passwords/KeychainStore.swift:72-78`.

**Symptômes**
- Une authentification réussie vaut 60 s pour **toutes** les actions. Après un remplissage, n'importe qui devant le Mac peut, dans la minute, afficher ou copier **tous** les mots de passe dans les Réglages sans Touch ID.
- Une fois déverrouillée, la liste des Réglages (mots de passe révélés compris) reste affichée tant que la vue existe. Aucun reverrouillage quand on change d'onglet de réglages ou quand l'app passe en arrière-plan.
- `logins(matching:)` propose un identifiant enregistré pour `exemple.fr` sur **tout** sous-domaine (`n-importe-quoi.exemple.fr`), et inversement. C'est risqué avec les sous-domaines contrôlés par des tiers.

**Correction**
- Pas de délai de grâce pour afficher ou copier (garder 60 s seulement pour le remplissage).
- `unlocked = false; revealed = [:]` dans `.onDisappear` et à `NSApplication.didResignActiveNotification`.
- Faire correspondre l'hôte exact, ou le même domaine enregistrable (liste des suffixes publics). Le cas parent/enfant pourrait être signalé dans le menu (« identifiant de exemple.fr »).

---

## 🟡 23. Divers

| Sujet | Où | Correction |
|---|---|---|
| Import Chrome : les favoris de la barre arrivent tous dans un dossier « Barre de favoris » (le nœud racine est pris pour un dossier). Import Firefox : dossiers « toolbar », « menu », « unfiled ». | `BrowserImporter.swift:144-152, 207-214` | Ne pas propager le nom des nœuds racine (`roots.*`, et les parents 1 à 5 de Firefox). |
| Import CSV : un fichier UTF-8 avec BOM (exporté depuis Excel) donne 0 mot de passe, car l'en-tête `\u{FEFF}url` n'est pas reconnu. | `BrowserImporter.swift:234-241` | Retirer le BOM : `text.trimmingPrefix("\u{FEFF}")`. |
| Masquer un élément : `isPickingElement` n'est lu nulle part et reste à `true` si la page navigue pendant la sélection. Un sélecteur refusé par le compilateur de règles fait échouer **toute** la liste masquée. | `ElementHider.swift:23-36`, `ContentRules.swift:77-87` | Supprimer la propriété, ou la remettre à `false` au commit. En cas d'échec de compilation, recompiler hôte par hôte et écarter la règle fautive. |
| `core.js` ajoute `allow="picture-in-picture; fullscreen"` et `allowfullscreen` à **toutes** les iframes, publicités tierces comprises, contre le choix du site. | `core.js:26-32` | Se limiter aux lecteurs connus (YouTube, Vimeo, Dailymotion…) ou à `picture-in-picture` seul. |
| Lecture automatique avec son autorisée partout (`mediaTypesRequiringUserActionForPlayback = []`). | `WebViewFactory.swift:51` | En faire un réglage, ou bloquer l'audio sans geste (`.audio`). |
| Historique : les navigations des applications web (`pushState`) ne sont jamais enregistrées, puisque seul `didFinish` enregistre. | `TabWebDelegate.swift:102-106` | Enregistrer aussi depuis l'observation de `url` pour les changements de même origine (avec un délai anti-rafale). |
| Zoom : ⌘+ exige ⇧ sur la plupart des claviers, et ⌘= ne fait rien. | `VoidCommands.swift:72-73` | Ajouter un bouton caché avec `.keyboardShortcut("=")`. |
| Deux Void lancés au même instant se voient mutuellement et **quittent tous les deux**. | `SingleInstance.swift:10-19` | Verrou exclusif (`flock` sur un fichier de `Application Support`) : seul celui qui l'obtient reste. |
| Libellés de la conservation de l'historique : « Effacer l'historique : Une fois par an » laisse croire à un effacement annuel complet, alors qu'il s'agit de garder les pages visitées depuis moins d'un an. | `AppSettings.swift:34-40`, `SettingsView.swift:343` | « Conserver l'historique : 1 an / 6 mois / 90 jours / 30 jours ». |
| `FloatingPlayer.restore()` sort sans remettre `tab` et `videoFrame` à zéro si l'onglet a été endormi entre-temps. | `FloatingPlayer.swift:98-109` | Remettre ces propriétés à zéro avant le `guard`. |
| Recherche dans l'historique : `_` n'est pas échappé dans `LIKE` (joker d'un caractère). | `HistoryStore.swift:67-75` | `LIKE ? ESCAPE '\'` en échappant `%`, `_` et `\`. |

---

## Points vérifiés et jugés corrects

Pour éviter de les réexaminer :
- Cloisonnement des scripts de Void dans un monde isolé : les pages ne peuvent ni lire ni appeler les gestionnaires `voidAutofill`, `voidStore`, etc.
- Remplissage des mots de passe : origine du cadre vérifiée côté Swift (`securityOrigin`) et côté JS avant d'écrire.
- Barre d'adresse : l'URL n'est affichée qu'au *commit* pour une navigation vers une autre origine, ce qui empêche l'usurpation d'adresse pendant le chargement.
- Mode lecture : HTML reconstruit à partir d'une liste blanche, affiché sans JavaScript et avec une CSP stricte ; les balises `meta` (dont `refresh`) sont supprimées.
- Nom des fichiers téléchargés : caractères bidirectionnels, séparateurs et fichiers cachés neutralisés ; quarantaine posée.
- Fenêtres privées : pas d'historique, de favicon en cache, de formulaires, de mots de passe ni de session ; le magasin est vidé à la fermeture.
- Chargement de la session tolérant aux données abîmées, avec copie de secours.
- Aucune dépendance au fil d'exécution suspecte : tous les rappels marqués `MainActor.assumeIsolated` arrivent bien sur le fil principal (KVO de WKWebView, `WKDownloadDelegate`, moniteurs d'évènements, `DispatchSource` sur la file principale).
