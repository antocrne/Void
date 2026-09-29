# Rapport R1 — Le Visionnaire et avocat du diable

Contexte lu : README.md, arborescence Void/ (8 051 lignes Swift), CommandBar.swift (suggestions : go/search/switchTo/download/action), FeatureSelfTest.swift (harnais DEBUG). Constat : aucune occurrence de AppIntent, NSUserActivity, Spotlight, FoundationModels, NSSharingService dans le code : tout le terrain « intégration système » est vierge. Note : le README dit ~5 700 lignes, le code en compte ~8 050 (doc en retard).

---
## A. Avocat du diable

### Pourquoi Void pourrait stagner
1. **Le slogan « qui s'efface » est aussi une pente vers l'indifférenciation.** Onglets latéraux, espaces, épinglés, PiP, lecture, bloqueur : c'est Arc/Zen/Orion/SigmaOS avec moins de tout. Rien n'est un « pourquoi je quitterais Safari » en une phrase. Safari a déjà : profils, groupes d'onglets, synchro iCloud, passkeys, extensions, Handoff.
2. **Le moteur est celui de Safari, donc le plafond aussi.** Aucun gain de perf, de compatibilité ou de sécurité face à Safari ; les sites « Chrome-only » cassent. Le seul levier durable est l'expérience (UI, automatisation, intégration système), pas le rendu.
3. **La confiance est le vrai produit d'un navigateur** : mots de passe, mises à jour de sécurité WebKit (Void suit macOS, OK), signature ad hoc sans compte développeur = pas de mise à jour auto, pas de notarisation, Gatekeeper hostile. Sans distribution propre, l'audience reste le développeur lui-même.
4. **Dette de vérification.** Beaucoup de ☑️ « non testé » (mots de passe, import, inspecteur, extensions) sur des zones à haut risque (trousseau, profils d'autres navigateurs). Un seul incident de perte/fuite de données tue la crédibilité. Le harnais d'auto-test est un vrai atout, mais il est concentré sur PiP et UI.
5. **APIs internes WebKit (WebKitSPI)** : chaque mise à jour macOS peut casser PiP/console ; dette d'entretien récurrente pour un solo.
6. **Risque de dispersion par agents IA** : la vitesse de production de code (8 000 lignes) dépasse la capacité de validation humaine. Le goulot n'est plus l'écriture, c'est la vérification et la cohérence produit.

### Pièges de la roadmap implicite (section « Non implémenté » et 🟡)
| Chantier | Verdict | Pourquoi |
|---|---|---|
| **Synchronisation entre appareils** | **REFUSER** | Exige un backend ou CloudKit + compte développeur payant, résolution de conflits, chiffrement bout-en-bout, support. Sans version iOS, la valeur est quasi nulle. Alternative gratuite : export/import d'un fichier de profil, ou dossier iCloud Drive (fichier JSON) plus tard. |
| **Passkeys** | **REFUSER (pour l'instant)** | ASAuthorization dans une WKWebView exige des entitlements (associated domains / navigateur « web browser public-key credential » demandé à Apple) ; impossible en signature ad hoc. Le système gère déjà les passkeys via iCloud Keychain dans Safari uniquement. À rouvrir seulement si Void obtient un compte développeur et l'entitlement. |
| **Extensions web complètes (chrome.tabs/windows)** | **GELER** | `WKWebExtension` (macOS 15.4+) est déjà là ; brancher tabs/windows = API de délégation lourde (WKWebExtensionController + delegate d'onglets/fenêtres), et la compatibilité réelle dépend d'extensions tierces non testables sans intervention humaine. Faire uniquement : uBlock-like et gestionnaire de mots de passe (1 ou 2 extensions cibles), sinon couper la promesse du README. |
| **Cartes bancaires / autofill avancé** | **REFUSER** | Responsabilité sécurité/PCI-adjacente, valeur faible ; laisser le système (Safari/Apple Pay) ou un gestionnaire externe. |
| **Listes de blocage externes (EasyList)** | **DIFFÉRER** | Limite WKContentRuleList (~150 000 règles/liste, compilation lente, conversion de syntaxe ABP). Utile mais chantier de conversion + tests ; les ~150 règles actuelles suffisent à l'identité « léger ». Si fait : liste convertie et figée, pas de mise à jour réseau. |
| **Blocage pubs YouTube in-stream** | **REFUSER** | Course aux armements permanente ; épuise un solo. |
| **Gestion fine des permissions par site** | **FAIRE PETIT** | WKUIDelegate expose déjà caméra/micro/géoloc ; un tableau « Confidentialité → permissions par site » est peu coûteux et cohérent avec « qui s'efface » (à condition de ne pas ajouter de popups). |
| **Import de mots de passe Chrome/Arc** | **VALIDER OU COUPER** | Code jamais exécuté sur de vrais profils. Soit test sur un profil jetable fabriqué en fixture (SQLite + clé de test), soit retirer le mot de passe de l'import et garder favoris/historique. |
| **Restauration des fenêtres ⌘N** | **FAIRE** (petit) | Incohérence visible ; correctif borné. |

### À couper ou refuser (liste sèche)
Synchro, passkeys, cartes bancaires, pubs YouTube, Chromium/Blink-compat, tout « mode IA » cloud (dépendance, vie privée : contraire au slogan), thèmes/personnalisation supplémentaires (l'onboarding en fait déjà beaucoup), toute nouvelle option de réglage qui n'a pas de valeur par défaut évidente. Règle proposée : **toute fonctionnalité doit s'éteindre sans laisser de trace visuelle** ; sinon elle contredit le slogan.

---
## B. Vision à 6 mois : 8 idées

Thèse : Void ne gagnera pas sur « un navigateur de plus », mais comme **le navigateur natif Mac le plus scriptable et le mieux intégré au système**, à mémoire longue et locale. Le levier : ce que Chromium/Electron ne peuvent pas faire (App Intents, Spotlight, Foundation Models, Handoff, Partage).

### 1. Void comme citoyen App Intents / Raccourcis (Shortcuts)
- **Valeur** : très haute et différenciante. « Ouvrir cette URL dans l'espace X », « Lister les onglets », « Obtenir le texte de la page », « Enregistrer la page en Markdown/PDF ». Débloque Spotlight actions, Siri, Focus filters, Raccourcis, automatisations (avec le mode Focus).
- **Faisabilité** : AppIntents (macOS 13+), `AppEntity` pour Tab/Space avec `EntityQuery`, `AppShortcutsProvider`. Nécessite que l'app soit lancée via le système : fonctionne en signature ad hoc, mais l'indexation Raccourcis est plus fiable avec un bundle identifier stable. Les intents s'exécutent dans le process de l'app (`openAppWhenRun`) : bien adapté à BrowserModel.shared.
- **Effort** : S à M (1 à 2 semaines pour 6-8 intents). **Risque** : faible. Piège : intents appelés app fermée ; prévoir file d'attente au démarrage.

### 2. Recherche plein texte dans l'historique (« se souvenir de ce que j'ai lu »)
- **Valeur** : haute, comble un vrai manque de tous les navigateurs. Barre ⌘L qui trouve « cet article sur les trous noirs lu la semaine dernière ».
- **Faisabilité** : à la fin du chargement, extraire le texte via le pipeline du mode lecture (reader.js existe déjà) ; stocker dans SQLite **FTS5** (SQLite système : FTS5 est compilé sur macOS). Option : classement par `bm25()`. Exclure fenêtres privées, domaines sensibles (banque, mails), champs de formulaire ; plafond de taille ; purge par durée. Bonus : indexation Core Spotlight (CSSearchableItem) pour que Spotlight trouve les pages.
- **Effort** : M (2 à 3 semaines, la vie privée demande du soin). **Risque** : moyen, dépend des exclusions et du poids disque ; tout est local, aucune donnée sortante.

### 3. Onglets qui s'archivent seuls + « Rappels de lecture »
- **Valeur** : haute, cohérente avec « s'efface » : le navigateur nettoie lui-même. Onglet non touché depuis N jours (non épinglé) → archivé dans une liste consultable (titre, favicon, extrait), restaurable avec ⌘⇧T étendu ; recherche via la barre ⌘L.
- **Faisabilité** : le mécanisme de mise en veille à 30 min existe déjà (Tab, timers) ; il faut un `ArchivedTab` persisté (StateStore) et une UI de liste (LibraryView existe). Aucune API exotique.
- **Effort** : S à M. **Risque** : faible ; attention à la perte de confiance si un onglet important disparaît → toujours annulable, jamais silencieux, exclusions strictes (saisie en cours, épinglés, audio).

### 4. Résumés et actions locales via Apple Foundation Models (macOS 26+)
- **Valeur** : moyenne à haute, mais **fort effet de vitrine** : « résume cette page », titres d'onglets/archives auto-générés, réponse à une question sur la page, tri des téléchargements, mode lecture avec « en 3 lignes ». 100 % local, cohérent avec la vie privée.
- **Faisabilité** : framework `FoundationModels` (macOS 26) : `LanguageModelSession`, sorties structurées avec `@Generable`, streaming ; vérifier `SystemLanguageModel.default.availability`. Fenêtre de contexte limitée (~4 k tokens) : découper (map-reduce) le texte extrait par le mode lecture. Le projet cible macOS 14 : isoler derrière `#if canImport(FoundationModels)` + `@available(macOS 26, *)` ; rien ne doit casser sur les anciennes versions. Le modèle n'est disponible que sur Apple silicon avec Apple Intelligence activé.
- **Effort** : M. **Risque** : moyen (disponibilité, qualité variable en français, tests non déterministes → auto-test limité à « la disponibilité est bien gérée et l'UI ne plante pas »). Ne jamais l'activer par défaut ni envoyer de texte hors de l'appareil.

### 5. Mode Focus / « Sessions » liées à un contexte
- **Valeur** : haute pour la thèse « s'efface » : un espace = un contexte ; un **Filtre de Concentration** (Focus Filter, `SetFocusFilterIntent`) macOS bascule automatiquement Void sur l'espace « Travail » ou masque l'espace « Perso » ; en plus, un mode « lecture seule sans distractions » (barres masquées, notifications de sites coupées, sites bloqués temporairement).
- **Faisabilité** : `SetFocusFilterIntent` (App Intents, macOS 13+) ; réutilise Space, AppSettings, ContentRules (liste de blocage temporaire dynamique). 
- **Effort** : S à M. **Risque** : faible ; dépend de l'idée 1 (même socle App Intents).

### 6. Aperçu de lien (« peek ») et vue scindée (split view)
- **Valeur** : moyenne à haute. Peek : maintenir ⌥ ou Espace sur un lien → petite fenêtre flottante (WKWebView dans un panneau) qui disparaît si on clique ailleurs ; « promouvoir en onglet » d'un geste. Split view : deux pages côte à côte dans une même fenêtre (glisser un onglet vers le bord ou commande palette).
- **Faisabilité** : peek = NSPanel/popover avec 2e WKWebView réutilisant l'espace courant ; s'appuie sur le menu contextuel et core.js existants (détection du lien survolé). Split view = le modèle « une vue web active par fenêtre » (PageView/WebHost) doit devenir « une ou deux » : refactor du modèle de sélection (Space → groupes d'onglets) ; le plus lourd est l'état (quel onglet a le focus, ⌘L, raccourcis).
- **Effort** : peek S à M, split M à L. **Risque** : peek faible ; split moyen (régressions sur les raccourcis et la persistance de session, et sur le glisser-déposer de la barre latérale). Recommandation : peek d'abord, split ensuite si l'usage le demande.

### 7. Intégrations système « à la Mac » : Partage, Handoff, Spotlight, Services
- **Valeur** : moyenne, mais elle fait « app Mac de qualité » (attendu par les utilisateurs Mac exigeants) pour un coût faible.
- **Faisabilité** : 
  - **Partage** : `NSSharingServicePicker` sur l'URL/la sélection (bouton ou menu) ; et **Share Extension** pour « Ouvrir dans Void » (cible d'extension séparée : plus lourde, à faire en dernier).
  - **Handoff** : `NSUserActivity` de type navigation web (`NSUserActivityTypeBrowsingWeb`, `webpageURL`) ; utile seulement s'il existe un pendant iOS/iPad ; ne rapporte rien aujourd'hui → **reporter**.
  - **Spotlight** : Core Spotlight (`CSSearchableItem`) pour favoris et pages archivées ; lié à l'idée 2.
  - **Services / URL scheme** : `void://open?url=...&space=...` (Info.plist `CFBundleURLTypes`) : très bon rapport effort/valeur pour l'automatisation, testable sans interface.
- **Effort** : S chacun (Share menu, URL scheme) ; Share Extension M. **Risque** : faible. Handoff : à éviter tant qu'il n'y a pas d'autre appareil.

### 8. Palette de commandes étendue + profils/espaces « intelligents » + automatisations par site
- **Valeur** : haute pour les utilisateurs avancés, à faible coût : la barre ⌘L (CommandBar) a déjà un cas `.action(() -> Void)`. Y ajouter : toutes les commandes du menu (« > basculer le thème », « > vider le cache de ce site »), commandes sur l'onglet (« déplacer vers l'espace… », « copier en Markdown »), recherche floue (fuzzy) sur onglets/historique/archives/réglages, alias de recherche (`yt trou noir`).
- **Automatisations par site** (règles) : « sur github.com → espace Travail, lecteur désactivé, zoom 110 % » ; « les liens de X s'ouvrent toujours dans l'espace Perso » : routage de liens par domaine → espace (Space + URL matching) ; scripts utilisateur légers (CSS/JS injectés par site) : l'infrastructure de l'ElementHider (règles par site, scripts en monde isolé) est déjà un premier pas.
- **Faisabilité** : 100 % code existant + petits modèles de données. 
- **Effort** : S (palette), M (règles par site). **Risque** : faible ; attention à ne pas créer un second système de réglages surchargé.

### Ordre de valeur/effort recommandé
1 (App Intents + URL scheme) → 8 (palette) → 3 (archivage auto) → 2 (FTS5) → 5 (Focus) → 4 (Foundation Models) → 6 (peek, puis split) → 7 (Partage). Pas de Handoff ni de synchro avant qu'un second appareil existe.

### Ce qui donnerait à Void une identité en une phrase
« Le navigateur Mac que l'on peut scripter, qui se souvient localement de tout ce que vous avez lu, et qui range tout seul. »

---
## C. TOP 5 des chantiers pour CETTE NUIT (agent seul, quelques heures, vérifiable par build + auto-test DEBUG)

Critères : périmètre borné, pas de dépendance réseau, pas de geste manuel, extension du harnais `FeatureSelfTest` (ajouter des `check(...)`), aucune API instable.

### 1. Schéma d'URL `void://` et arguments de ligne de commande (base d'automatisation)
- Livrable : `void://open?url=…&space=NOM&mode=background|foreground|private`, `void://search?q=…`, `void://space?name=…` ; enregistrement dans `Config/Info.plist` (`CFBundleURLTypes`) ; gestion dans `AppDelegate` (`application(_:open:)`) qui appelle `BrowserModel.open`.
- Auto-test : appel direct du parseur (fonction pure `VoidURLCommand.parse`) + ouverture d'un onglet réel dans l'espace jetable, vérification de l'URL, de l'espace, du mode ; rejet d'un schéma malformé ou d'une URL `javascript:`/`file:`.
- Pourquoi maintenant : socle des idées 1, 5, 8 ; très testable ; zéro UI. **Sécurité** : liste blanche de schémas (http/https uniquement), ne jamais exécuter de JS depuis l'URL.

### 2. App Intents de base (Raccourcis) : « Ouvrir dans Void », « Onglets ouverts », « Texte de la page »
- Livrable : `Void/App/Intents.swift` : `OpenURLIntent` (paramètres URL + `SpaceEntity` optionnel), `ListTabsIntent`, `GetPageTextIntent` (via le pipeline du mode lecture), `AppShortcutsProvider`. Réutilise la logique du chantier 1 (mêmes fonctions).
- Vérification : le build compile (entitlements inchangés) ; auto-test appelle `perform()` directement sur les intents (ce sont des structs Swift, appelables sans Raccourcis) ; vérifier que `ListTabsIntent` renvoie les titres du modèle.
- Risque : la découverte par l'app Raccourcis ne peut pas être testée sans intervention manuelle (à noter honnêtement en ☑️ dans le README) ; garder `openAppWhenRun = true`.

### 3. Palette de commandes étendue (barre ⌘L : préfixe `>`)
- Livrable : nouveau type `CommandCatalog` (liste de commandes nommées : thème, position des onglets, barre de favoris, mode lecture, épingler, aller à l'espace X, fenêtre privée, réglages, importer, etc.) exposée dans `CommandBar.suggestions` quand la saisie commence par `>` ou quand une correspondance floue forte existe ; recherche floue simple (sous-séquence + score). Utilise le cas `.action` déjà présent.
- Auto-test : `suggestions(for: ">thème")` renvoie la commande attendue, l'exécuter change réellement `AppSettings.theme` (puis restauration, comme le harnais le fait déjà) ; ordre de score stable ; aucune commande ne plante hors fenêtre principale.
- Effort : ~3 h ; forte valeur perçue, très faible risque.

### 4. Archivage automatique des onglets inactifs (liste « Archivés », restaurable)
- Livrable : réglage « Archiver les onglets inactifs après N jours » (désactivé par défaut ou 7 jours, à trancher), modèle `ArchivedTab` (URL, titre, date, espace) persisté dans StateStore, entrée dans la barre ⌘L (« Archivés : … » → rouvre) et section dans LibraryView. Exclusions : épinglés, sonores, en appel, texte saisi (même filtre que la mise en veille existante — le réutiliser).
- Auto-test : injecter une date d'activité ancienne sur un onglet de l'espace jetable, lancer le passage d'archivage, vérifier : onglet retiré, entrée archivée, exclusions respectées, restauration ramène l'URL ; persistance aller-retour JSON.
- Risque : perte perçue de contenu → ne jamais supprimer sans écrire l'archive d'abord ; ⌘⇧T doit aussi pouvoir restaurer.

### 5. Index plein texte de l'historique (SQLite FTS5) — socle local uniquement
- Livrable : table FTS5 `page_text(url, title, body)` dans la base d'historique existante (`SQLiteDB.swift`), remplie en fin de chargement par extraction de texte (réutiliser reader.js/`ReaderMode` en version « texte brut », plafonnée à ~50 ko), **jamais en fenêtre privée**, liste d'exclusion de domaines (banques, mails, `localhost`) et interrupteur dans Réglages → Confidentialité (avec bouton « Effacer l'index »). Requête `HistoryStore.search(fullText:)` classée par `bm25`, branchée dans la barre ⌘L sous une section « Dans vos pages lues ».
- Auto-test : charger 2-3 pages HTML locales (méthode `htmlTab` du harnais) avec des mots distinctifs, vérifier la requête plein texte, l'exclusion en fenêtre privée, l'exclusion de domaine, l'effacement de l'index ; vérifier que FTS5 est disponible (sinon repli propre : fonction désactivée, aucune erreur).
- Risque : le plus élevé du top 5 (vie privée, taille disque) → chantier à faire **derrière un réglage désactivé par défaut**, et à documenter clairement dans le README. Si le temps manque, livrer le schéma + l'indexeur + les tests sans branchement UI.

### Ordre conseillé pour la nuit
1 (url scheme) → 3 (palette) → 4 (archivage) → 2 (intents, réutilise 1) → 5 (FTS5, si le temps le permet). Chaque chantier : un commit, build Debug + `-VoidSelfTest features` vert avant le suivant ; mettre à jour le README honnêtement (✅ seulement si test automatique réel ; ☑️ pour la découverte Raccourcis).

### Hors périmètre de la nuit (à ne pas confier à un agent seul)
Foundation Models (qualité non déterministe, macOS 26 requis pour tester), split view (refactor profond), peek (geste/UI à valider à la main), synchro, passkeys, extensions chrome.tabs, listes EasyList.
