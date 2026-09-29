# Rapport R1 — Produit & UX (conseil des agents, Void)

Méthode : README, captures ui-sidebar-dark / ui-command-bar, lecture de CommandBar, AddressPill, BrowserWindowView, PageView, SidebarView, TabWebDelegate, DownloadManager, AppSettings, URLResolver, VoidCommands, SettingsView (grep). Rien n'a été modifié.

## 1. Identité de Void

**Promesse** : « un navigateur qui s'efface » = une page, chrome minimal, WebKit natif, 5 Mo, zéro dépendance, 100 % français.

**Ce qui différencie réellement**
- Fidélité native macOS + légèreté : WebKit, Touch ID/trousseau, PiP à 3 niveaux (le plus abouti que j'aie vu hors Safari), ~5 Mo. Arc/Zen/Dia sont lourds ; Safari est natif mais n'a pas la barre latérale d'Arc.
- Espaces à stockage réellement isolé (`WKWebsiteDataStore(forIdentifier:)`) : proche des profils Safari, sans la lourdeur.
- Command bar unique (URL + recherche + onglets + favoris + historique + téléchargements + actions) : très « Arc/Raycast ».
- Sidebar masquée jusqu'au bord gauche (⌘S) + page plein cadre : c'est la traduction la plus littérale du slogan.
- Mise en veille des onglets (préserve position + historique), mode lecture, masquage d'éléments durable par site, bloqueur natif sans script. Tout cela dans 5 700 lignes.
- Honnêteté du README (✅ testé / ☑️ / 🟡 / ❌) : rare, et une vraie marque de confiance.

**Juste « un navigateur de plus »**
- Sidebar verticale + onglets épinglés en grille + espaces + command bar : c'est Arc (et Zen, Dia) presque point pour point. Pris isolément, ce n'est plus un différenciant en 2026.
- Bloqueur ≈ 150 règles, mode lecture, PiP, import : cases cochées par Safari/Orion.
- Thème sombre par défaut, couleur d'accent : cosmétique.
- Le minimalisme est pour l'instant un *style* (peu de boutons) plus qu'un *comportement* : le chrome ne s'efface pas de lui-même, l'utilisateur doit le configurer (⌘S, réglages).

**Positionnement vs concurrents** : Safari = natif mais ancien et sans sidebar ; Arc = meilleur modèle mental mais abandonné/lourd ; Zen = Firefox, communautaire, extensions ; Orion = WebKit + extensions Chrome/Firefox, gros support ; Dia = IA. Void occupe la case « Arc-like natif, léger, français, sans IA, sans compte ». Case valable mais étroite ; il manque un fait d'armes mémorable (voir §4).

## 2. Frictions UX probables (avec fichiers)

**Premier lancement**
- `Features/Onboarding/OnboardingView.swift` (409 l.) personnalise l'apparence avant que l'utilisateur ait vu une page ; aucune étape « importer mes favoris/mots de passe » ni « définir par défaut » n'est proposée dans le flux (ils sont enfouis dans `Settings/SettingsView.swift`, ImportSection l.438). Or l'import est le n°1 de la première semaine.
- Thème sombre imposé par défaut (`AppSettings.swift` : `theme ... ?? .dark`) alors que la page reste blanche (cf. capture) : contraste brutal, et un utilisateur système clair sera surpris. « Système » devrait être le défaut.
- Moteur par défaut Google (`AppSettings.swift`) sans choix à l'onboarding, alors que le public visé (minimaliste, français) préférera souvent DDG/Qwant/Kagi.

**Navigation**
- `UI/PageView.swift` l.16 : `NewTabPage()` n'apparaît que quand il n'y a aucun onglet ; ⌘T ouvre la command bar (`VoidCommands.swift` l.13), donc pas de page d'accueil/raccourcis : un onglet « Nouvel onglet » vide n'existe pas. Cohérent avec le concept, mais pas de favoris/récents visibles quand on n'a pas encore d'habitude.
- `Web/TabWebDelegate.swift` l.105 : erreurs réseau → `ErrorOverlay` avec simple bouton recharger ; `webViewWebContentProcessDidTerminate` recharge en silence (boucle possible sur une page qui plante).
- `AddressPill.swift` : l'adresse n'affiche que l'hôte (`addressText`) — joli, mais on ne voit jamais le chemin, ni de vrai indicateur de sécurité (cadenas seul, pas d'alerte HTTP explicite), ni de sélection/copie directe : il faut ouvrir la command bar. Les outils (lecture, bloqueur, favori) n'apparaissent qu'au survol (`showAll: hovering`) : découvrabilité faible.
- `URLResolver.swift` : pas de chemin « mot-clé de recherche » (`w fr chat`), ni de gestion des URLs sans point type `intranet/` ; une saisie avec espace est toujours une recherche : correct.

**Gestion d'onglets**
- `UI/SidebarView.swift` : liste plate d'onglets, sans dossiers/groupes, sans recherche d'onglets propre, sans indication de mémoire/sommeil autre que la miniature de veille ; la capture montre 9 onglets « Example Domain » indiscernables (titres identiques, lettres) → besoin d'un URL secondaire au survol / dédoublonnage.
- Les onglets se ferment sans confirmation, mais ⌘⇧T existe (bien). Rien pour « tout fermer sauf celui-ci », ni fermeture automatique des onglets vieux (ex. Arc archive à 12 h).
- `sleepInactiveTabs` fixé à 30 min en dur (`BrowserModel.swift` l.85), non réglable.
- Fenêtres ⌘N : onglets non restaurés (README), épinglage limité à la fenêtre principale → surprenant pour un utilisateur multi-fenêtres.
- Drag & drop en barre du haut impossible (déjà acté, hors sujet).

**Recherche**
- `UI/CommandBar.swift` : très bon, mais : pas de suggestions distantes du moteur (autocomplétion Google/DDG), pas de préfixes (`@histo`, `@onglets`), résultat unique « Ouvrir » vs « Rechercher » ; limite 12 ; actions limitées à 4 (téléchargements, historique, favoris, réglages). Pas de « Fermer les onglets », « Changer d'espace », « Mode lecture »… alors que c'est le lieu naturel pour une palette de commandes.
- L'historique n'a pas de recherche en texte intégral, ni de suggestion « page déjà ouverte » qui priorise l'onglet existant à la saisie d'une URL déjà ouverte.

**Téléchargements**
- `Features/Library/DownloadManager.swift` : uniquement toast + rebond du Dock + vue Bibliothèque. Pas de popover/tiroir de téléchargements près de la sidebar (l'icône du bas de la sidebar existe, mais pas de progression inline), pas de pause/reprise (`resumeData` ignoré dans `didFailWithError`), pas de « Ouvrir » au clic dans le toast, pas d'avertissement pour les fichiers exécutables, pas d'ouverture auto des PDF dans l'onglet (les PDF sont-ils affichés inline ? `canShowMIMEType` oui pour WebKit, OK).

**Réglages**
- `Settings/SettingsView.swift` (558 l.) : onglets Général / Onglets / Confidentialité / Extensions ; beaucoup d'options, ce qui va un peu à l'encontre du slogan. Les permissions par site (caméra, micro, position, notifications) sont absentes : `Web/TabWebDelegate.swift` commente « (Camera/mic: not implementing… keeps WebKit's default, which prompts) » → prompt à chaque session, aucun endroit pour révoquer.
- Pas de gestion des cookies/données par site en dehors du réglage global « Données de navigation ».

## 3. Fonctionnalités manquantes remarquées en première semaine (impact / effort)

| # | Fonction | Impact | Effort | Note |
|---|---|---|---|---|
| 1 | Autocomplétion distante du moteur (suggestions de recherche) | Haut | Faible | URL JSON du moteur, cache ; `CommandBar.swift` |
| 2 | Permissions par site (micro, caméra, position, notifs) + révocation | Haut | Moyen | `WKUIDelegate.requestMediaCapturePermission`, `Settings` |
| 3 | Popover/tiroir de téléchargements + reprise + « Ouvrir »/« Afficher » | Haut | Faible-moyen | `DownloadManager`, `SidebarView` |
| 4 | Onboarding : import + navigateur par défaut + moteur | Haut | Faible | `OnboardingView` |
| 5 | Thème « Système » par défaut | Moyen | Très faible | `AppSettings` |
| 6 | Palette de commandes étendue (actions, préfixes, changer d'espace, fermer les doublons) | Haut | Faible | `SuggestionEngine` |
| 7 | Onglets : dédoublonnage/aller à l'onglet existant, tout fermer sauf, groupes | Moyen | Moyen | `BrowserModel`, `SidebarView` |
| 8 | Restauration des onglets des fenêtres ⌘N | Moyen | Moyen | `StateStore`, `BrowserWindows` |
| 9 | Zoom par site mémorisé | Moyen | Faible | déjà `browser.zoom` global |
| 10 | Partage (NSSharingServicePicker), AirDrop, Handoff, « Copier en Markdown » | Moyen | Faible | `VoidCommands` |
| 11 | Passkeys, remplissage cartes, formulaires multi-étapes | Haut | Élevé | hors soirée |
| 12 | Sync entre appareils (iCloud) | Haut | Très élevé | hors soirée |
| 13 | Chrome.tabs pour extensions | Moyen | Élevé | hors soirée |
| 14 | Listes de blocage externes (EasyList) | Moyen | Moyen | `AdBlockList`, conversion WKContentRuleList |
| 15 | Traduction de page (Translation framework macOS 15) | Moyen | Moyen | en français : utile |
| 16 | HTTPS-only / avertissement HTTP, page d'erreur enrichie | Moyen | Faible | `TabWebDelegate` |

## 4. Trois idées « signature » (navigateur qui s'efface)

1. **Le chrome qui s'évapore selon le contexte** : la sidebar et les outils d'adresse se retirent automatiquement quand la page est en lecture (défilement continu, vidéo plein cadre, mode lecture) et reviennent au moindre mouvement vers le bord ou à ⌘L. Aujourd'hui `sidebarAutoHide` est un interrupteur statique ; le rendre *adaptatif* (heuristique : scroll, vidéo, saisie dans un champ) serait le vrai « s'efface ». Personne ne le fait bien : Arc/Safari ont un mode compact figé.
2. **Onglets qui s'effacent tout seuls** : cycle de vie doux — un onglet non touché passe en veille (déjà là), puis « s'estompe » dans la sidebar (opacité/regroupement en « Anciens »), puis est archivé dans un historique consultable par la command bar, sans jamais demander de confirmation. Arc archive à durée fixe et opaque ; Void peut rendre le processus visible, réversible (⌘⇧T) et sans bruit. Combine sleep + archive + dédoublonnage.
3. **Page-sans-friction (« effaceur » de bruit)** : bannière cookies / pop-ups d'abonnement / overlays masqués automatiquement avec un seul geste (⌘⇧H existe) qui *apprend* : « masquer cet élément sur tous les sites de ce genre » (règles partagées, sélecteurs communs `[class*=cookie]`, `[id*=consent]`), plus mode « Page nue » (couper scripts tiers + trackers + éléments fixes) en un raccourci. C'est la version « cosmétique » du bloqueur, avec un effet immédiat visible.

## 5. TOP 5 chantiers pour cette nuit (agent seul, vérifiable par build + auto-test DEBUG)

1. **Suggestions de recherche distantes + palette de commandes étendue** (`UI/CommandBar.swift`, `App/AppSettings.swift`). Ajouter une source de suggestions (Google/DDG/Qwant/Kagi via leur endpoint JSON, timeout court, désactivable, jamais en privé sauf réglage), préfixes `>`/`@` (onglets, historique, favoris), actions supplémentaires (changer d'espace, mode lecture, fermer les doublons, nouvelle fenêtre privée). Vérif : test unitaire sur `SuggestionEngine` (injecter un faux fournisseur), auto-test `features`.
2. **Permissions par site + tiroir de téléchargements** (`Web/TabWebDelegate.swift`, `Features/Library/DownloadManager.swift`, `UI/SidebarView.swift`, `Settings/SettingsView.swift`). (a) implémenter `requestMediaCapturePermission` avec mémoire par site (autoriser/refuser/demander) et une section Réglages pour révoquer ; (b) popover de téléchargements depuis l'icône du bas de la sidebar avec progression, Ouvrir/Afficher, reprise via `resumeData`. Vérif : auto-test d'un `DownloadItem` local (`file://`) et de la persistance des permissions (`UserDefaults`).
3. **Onboarding utile + défauts sains** (`Features/Onboarding/OnboardingView.swift`, `App/AppSettings.swift`, `Settings/DefaultBrowser.swift`). Thème par défaut = Système, étape « moteur de recherche » (avec DDG/Qwant/Kagi mis en avant), étape « Importer depuis… » détectant les navigateurs installés, bouton « Définir Void par défaut ». Vérif : le test existant de l'onboarding + un nouveau qui parcourt les étapes.
4. **Gestion des onglets « qui s'efface »** (`Browser/BrowserModel.swift`, `UI/SidebarView.swift`, `UI/TabViews.swift`, `Settings/SettingsView.swift`). Réglage du délai de veille (au lieu des 30 min en dur), dédoublonnage (« aller à l'onglet existant » quand on ouvre une URL déjà ouverte), menu contextuel « Fermer les autres / les onglets sous celui-ci / les doublons », sous-titre du domaine au survol pour distinguer les onglets de même titre (cf. capture : 9 « Example Domain »). Vérif : auto-test (créer N onglets, appeler les actions, contrôler `space.tabs`).
5. **HTTPS d'abord + page d'erreur enrichie + zoom par site** (`Web/TabWebDelegate.swift`, `UI/Overlays.swift`, `Browser/BrowserModel+Actions.swift`, `UI/AddressPill.swift`). Mise à niveau automatique http→https avec repli, indicateur « Non sécurisé » dans la pastille, page d'erreur avec causes (hors ligne, DNS, certificat) et bouton « Réessayer / Ouvrir en http », protection contre la boucle de rechargement après `webViewWebContentProcessDidTerminate`, zoom mémorisé par hôte (`UserDefaults`). Vérif : tests sur `URLResolver` + un auto-test de navigation vers un serveur local.

Non retenus cette nuit (effort ou risque trop grands sans test manuel) : sync, passkeys, chrome.tabs, adaptation contextuelle du chrome (idée signature 1, à prototyper en isolant l'heuristique dans une classe testable à part), EasyList. Drag & drop barre du haut : exclu comme demandé.
