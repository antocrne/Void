# Conseil, tour 2 : le Contradicteur

Lecture seule. J'ai lu les 5 rapports et vérifié 9 affirmations dans le code (section 1.3). Aucun fichier du dépôt n'a été modifié.

## 1. Attaque des rapports

### 1.1 Recommandations surestimées, mal fondées ou hors esprit

**Vision, top 5 (URL scheme `void://`, App Intents, FTS5, archivage automatique).**
- Ce sont des fonctionnalités neuves, pas des corrections. Elles ajoutent de la surface : un schéma d'URL est un nouveau vecteur d'attaque, et l'index plein texte stocke le contenu lu par l'utilisateur.
- L'index FTS5 est le pire pour « un navigateur qui s'efface » : c'est un journal de tout ce qui est lu, donc un risque de vie privée. Il exige une liste d'exclusions, un réglage et un bouton d'effacement. Le Visionnaire le classe lui-même « le plus risqué ». Il ne devrait pas être dans un plan de nuit sans validation.
- Les App Intents ne sont pas testables de bout en bout (la découverte par Raccourcis reste manuelle), alors que la nuit vise des choses vérifiables par build et auto-test. Le rapport l'avoue, mais garde le chantier.
- L'archivage automatique est risqué : il fait disparaître des onglets sans que l'utilisateur ait rien demandé. Le rapport Produit propose la même idée en plus prudent (estomper, sans supprimer).

**Perf, chantier 4 : convertisseur EasyList.**
- Le rapport annonce lui-même un « prérequis » (chantier 3), un temps de compilation à mesurer, une mémoire à mesurer, une licence incertaine, et une URL de liste qui répond 404 pour l'alternative.
- Il ajoute du réseau au démarrage, alors que le Visionnaire veut « pas de dépendance réseau » et que le README vante 5 Mo et 150 règles.
- 300 lignes de convertisseur ne se relisent pas facilement au réveil. Et EasyList s'accompagne d'une promesse de protection que l'utilisateur devra maintenir.
- Verdict : hors de la nuit. Le seul morceau utile est le chantier 3 (ne plus retirer l'ancienne liste avant d'avoir compilé la nouvelle).

**Produit, chantier 1 : suggestions de recherche distantes.**
- Chaque frappe partirait vers Google/DDG. C'est contraire à « sans compte, sans IA, vie privée » et à la position « Kagi/Qwant » que le rapport recommande à côté.
- Le rapport le mentionne (« désactivable, jamais en privé ») sans mesurer que ce sera une fuite par défaut si l'option est activée.
- C'est aussi une dépendance à des endpoints non documentés.
- À reporter, ou à livrer désactivé par défaut.

**Produit, idée « signature » 3 : « Page nue » et règles apprises.**
- Sélecteurs génériques du type `[class*=cookie]` : ce sont des règles qui cassent des sites en silence.
- Le rapport Sécurité montre déjà qu'un seul sélecteur refusé fait échouer toute la liste `void-hidden`. Amplifier ce mécanisme est prématuré.

**Sécurité, 4.2 : demander confirmation pour les téléchargements de sous-cadres.**
- C'est de l'UX ajoutée (une invite), alors que le principe de Void est de ne pas interrompre. Il y a une alternative moins bruyante : refuser silencieusement les téléchargements de sous-cadres cross-origin sans geste.

**Sécurité, 2.3 : pastille d'origine 1,5 s en mode masqué.**
- Contradictoire avec le slogan et avec l'idée « signature » du rapport Produit (le chrome doit s'effacer). C'est un vrai compromis à trancher par le propriétaire, pas à imposer la nuit.

**Architecte, chantier 7 : `SWIFT_STRICT_CONCURRENCY = targeted`.**
- Sans mesure du nombre d'avertissements ni de leur nature. Ça peut produire un diff énorme, illisible, sans changement de comportement. Mauvais candidat pour un lot que l'utilisateur doit relire.

**Architecte, 1.7 et 1.8 (suppression de magasin, fermeture de fenêtre).**
- Fondés sur des suppositions [S] sur WebKit, avec un correctif lourd (liste « à supprimer » rejouée au lancement). Pas de preuve que le bug existe.

**Chevauchement inutile : Perf 5 (`interactionState` persisté) + Architecte 1 (session).**
- Les deux modifient `SavedTab`/`SavedState` et veulent chacun passer `version` à 2. À faire en un seul chantier, ou l'un après l'autre, jamais en parallèle.

### 1.2 Contradictions entre rapports

1. **Crash WebContent.**
   - Architecte : mettre en veille les onglets en arrière-plan, recharger une fois au premier plan.
   - Produit : simple « protection contre la boucle ».
   - Compatibles, mais l'Architecte en fait un chantier de 2 h avec la SPI `_killWebContentProcess` en test. Cette SPI n'est pas garantie et n'a jamais été utilisée dans le harnais, à vérifier.
2. **Quarantaine.** Sécurité et Architecte proposent le même correctif dans deux top 5 différents (Sécurité #3, Architecte #5). Doublon, conflit de fusion assuré sur `DownloadManager.swift`.
3. **Fullscreen sur les iframes (`core.js`).**
   - Sécurité : le restreindre.
   - Perf : optimiser les observateurs.
   - Le Visionnaire n'en parle pas.
   - Les trois touchent `core.js` et `media.js` : PiP est la fonction la plus fragile et la plus vantée. La fidélité au PiP doit primer.
4. **Persistance.**
   - Perf : sortir `saveNow` du thread principal, stocker les favicons à part.
   - Architecte : session incassable.
   - Les deux modifient le même format.
5. **Barre d'adresse.**
   - Sécurité : `committedURL`.
   - Produit : indicateur « non sécurisé » et zoom par site dans `AddressPill`/`TabWebDelegate`.
   - Même fichier, autre intention.
6. **Barre de commande.**
   - Perf #1, Produit #1 et Vision #3 réécrivent tous `CommandBar.suggestions`.
   - Trois agents, un seul fichier : il faut un ordre strict ou un seul propriétaire.
7. **Nombre de chantiers.**
   - Chaque rapport propose 5 chantiers de 1 à 3 h, soit 25 chantiers.
   - Une nuit n'en tient pas 25, et on n'a aucun budget de temps global.
8. **Adblock.**
   - Vision : « les ~150 règles suffisent, différer EasyList ».
   - Perf : convertir EasyList.
   - Contradiction frontale, Vision a raison pour cette nuit.
9. **Signature du produit.**
   - Vision : « scriptable et mémoire locale ».
   - Produit : « chrome qui s'évapore ».
   - Deux identités incompatibles. L'utilisateur doit choisir, pas la nuit.

### 1.3 Affirmations vérifiées dans le code

| # | Affirmation | Verdict |
|---|---|---|
| 1 | Sécurité 1.1 / Architecte 2.1 : `PasswordManager.swift:77-81` retente `fill` dans le cadre principal sans contrôle d'origine. | **Tient.** Confirmé aux lignes 77-81. Le scénario d'attaque de Sécurité (iframe qui disparaît pendant Touch ID) est plausible mais compliqué. Le correctif (supprimer le repli) reste sans regret. |
| 2 | Sécurité 4.1 : aucune quarantaine explicite. | **Tient.** `grep quarantine` : 0 résultat. `downloadDidFinish` (`DownloadManager.swift:115-124`) ne pose rien. L'effet réel reste supposé : 2 min avec `xattr -l` suffisent avant de coder. |
| 3 | Architecte 1.5 : `TabWebDelegate.swift:108-110` recharge sans condition. | **Tient.** `webView.reload()` seul. Pas de garde contre une boucle. |
| 4 | Architecte 1.2 : `BrowserModel.swift:191-195` lance l'exit PiP en `Task` puis appelle `sleep()`, qui sort si `isInPiP`. | **Tient** (lignes 191-195 et `Tab.swift:136`). Mais impact faible : cas rare (⌘W sur un épinglé en PiP). |
| 5 | Perf 1.A : `CommandBar.swift:88` calcule les suggestions dans `body`, `id = UUID()` change à chaque évaluation. | **Tient.** Lignes 88 et 11-12. C'est le meilleur constat de perf du conseil, correctif à fort rapport. |
| 6 | Sécurité 2.1 : `AddressPill` utilise l'URL provisoire. | **Tient partiellement.** `Tab.swift:200-204` suit bien `wv.url` et `AddressPill.swift:40` teste `scheme == "https"`. Que `WKWebView.url` renvoie l'URL provisoire est supposé (le rapport le dit). À tester en 5 min avant de classer 🔴. |
| 7 | Produit : « `sleepInactiveTabs` fixé à 30 min en dur (`BrowserModel.swift:85`), non réglable ». | **Tient, mais avec nuance.** Le code déclare `static var tabSleepDelay` avec le commentaire « Settings → Onglets ». `grep` montre 0 affectation en dehors de la déclaration : le réglage n'est pas branché. Le commentaire est faux : c'est un vrai petit bug de doc/UI. |
| 8 | Produit : « `ErrorOverlay` avec simple bouton recharger ». | **Tient** (`Overlays.swift:89-104`) : texte, hôte, bouton Réessayer. La page d'erreur existe, mais n'a aucun cas dédié (hors ligne, certificat). |
| 9 | Vision : « `Config/Info.plist` a `CFBundleURLTypes` pour http/https seulement ». | **Tient** (lignes 6-19). Ajouter `void://` est trivial, mais c'est aussi un vecteur pour une autre app ou un site. |
| 10 | Produit : « thème sombre par défaut ». | **Tient** (`AppSettings.swift:105` : `?? .dark`). |
| 11 | Perf : `HistoryStore` sur le thread principal. | **Non revérifié en détail**, cohérent avec ce que confirment deux rapports. |
| 12 | Tous : README obsolète (5 700 lignes). | Confirmé par trois rapports. C'est un correctif de deux minutes, mais aucun ne l'a mis en tête. |

Bilan : les constats de code sont fiables. Les failles viennent des recommandations, pas des faits : périmètre, chevauchement, ordre.

## 2. Angles morts de tout le conseil

1. **Accessibilité.** Le dépôt contient 17 occurrences du mot « accessibility » sur 8 000 lignes. Aucun rapport n'a évalué VoiceOver, la navigation au clavier de la barre latérale, la taille du texte dynamique, le contraste du thème sombre, ni « Réduire les animations » (`matchedGeometryEffect`). Un navigateur natif Mac sans VoiceOver correct est un défaut sérieux.
2. **Localisation.** Aucun `.lproj`, aucun `.xcstrings`, zéro `String(localized:)`. Tout est en français en dur. Assumé (« 100 % français »), mais aucun rapport ne mentionne le coût de sortir de cette hypothèse. Au minimum, une extraction de chaînes est la première étape de toute diffusion.
3. **Distribution et mises à jour.** Signature ad hoc (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`), pas de notarisation, pas de mise à jour automatique. Vision le note en passant. Aucun plan : DMG, notarisation (compte Apple à 99 €), Sparkle. C'est la barrière n°1 pour toute personne autre que le développeur, et elle est indépendante du code.
4. **Pages d'erreur réseau.** `ErrorOverlay` affiche `localizedDescription` en anglais système. Aucune distinction hors ligne / DNS / certificat invalide / HTTP 4xx. Aucun rapport n'a testé le comportement hors ligne. Le rapport Produit l'effleure (§2 et 5) mais sans y consacrer un chantier de nuit propre.
5. **Certificats invalides.** Sécurité constate « WebKit refuse » : donc une page d'erreur muette, sans explication. C'est cohérent en sécurité mais mauvais en UX, et personne ne l'a lié à l'angle mort précédent.
6. **Authentification HTTP.** Perf soulève l'absence de `didReceive challenge` mais la met « à vérifier ». Confirmé : `grep didReceive` dans `TabWebDelegate` est vide. Les sites en auth Basic (routeurs, intranets, NAS) échouent sans invite. C'est un bug fonctionnel réel de 30 lignes, absent de tous les top 5.
7. **Impression.** Existe (`printOperation`, `BrowserModel+Actions.swift:71`) mais aucun rapport ne l'a testée. `createPDF` (Perf) est cité et pas prioritaire.
8. **Plein écran.** `isElementFullscreenEnabled` est actif, mais rien sur le comportement de la barre latérale, du PiP ou du curseur en plein écran natif (macOS Spaces). Aucun test.
9. **Performance sur un Mac modeste.** Aucun rapport n'a mesuré quoi que ce soit (ils l'avouent). Les gains annoncés (suggestions, `media.js`) sont plausibles mais non chiffrés. Pas d'Instruments, pas de profil mémoire avec 30 onglets sur 8 Go, alors que la promesse est la légèreté.
10. **Onboarding.** Deux rapports en parlent (Produit), mais personne ne relève que l'onboarding fait 409 lignes, plus que la plupart des fonctionnalités, pour un produit « qui s'efface ». Le supprimer ou le réduire est une option qu'aucun rapport n'ose.
11. **Documentation et honnêteté du README.** Cité, jamais planifié. Le README est le contrat de confiance du produit (statuts ✅/☑️). Tout chantier doit le mettre à jour, mais aucun rapport n'a mis « README » dans ses livrables de façon systématique.
12. **Dette du harnais de test.** Architecte : l'auto-test touche les données réelles (`hidden-elements.json`, espaces orphelins). Chaque chantier ajoute des `check(...)` dans le même fichier `FeatureSelfTest.swift` (déjà modifié dans l'arbre de travail : `M Void/SelfTest/FeatureSelfTest.swift`). Trente `check` de plus dans un seul fichier, c'est un conflit de fusion garanti et un fichier illisible.
13. **Réglages / raccourcis clavier.** Personne n'a listé les raccourcis manquants ni vérifié la cohérence avec les conventions macOS (⌘⇧[ , ⌘1-9, ⌘⌥ flèches).
14. **Sauvegarde et données utilisateur.** Aucune exportation de session/favoris (le Visionnaire propose un fichier de profil comme alternative à la synchro, mais ne le planifie pas).

## 3. Vision alternative du plan de la nuit, en 5 points

Principe : l'utilisateur se réveille et veut **choisir quoi garder**. Donc des changements **indépendants** (un fichier ou un petit groupe de fichiers chacun), **petits** (un commit relisable en 5 à 10 minutes), **réversibles** (`git revert` d'un seul commit), qui **corrigent** ce qui existe, et qui n'ajoutent **ni réglage, ni surface, ni dépendance réseau**. Rien de nouveau qui demande un choix de produit.

1. **Lot « sans regret sécurité », 3 commits séparés, un par sujet.**
   - (a) Autofill : DÉJÀ FAIT ET COMMITÉ (info du coordinateur après rédaction). À retirer du plan de la nuit ; ne reste que le point 1.4 (vider `loginHost`/`loginFrame` au commit) s'il n'a pas été inclus, à vérifier dans le commit. Note : mes vérifications de la section 1.3 (ligne 1) portent sur l'état avant ce commit.
   - (b) Quarantaine des téléchargements, après vérification `xattr` (Sécurité 4.1 / Architecte 2.2).
   - (c) Dossier temporaire d'import supprimé (Architecte 2.3) et session des favicons sans cookies (Sécurité 5.1).
   - Pourquoi : 3 fichiers différents, aucune décision de produit, des tests possibles, et l'utilisateur peut jeter chacun sans effet sur les autres.
   - Volontairement exclu : `committedURL` (touche `Tab.swift`, `AddressPill` et la persistance, donc plusieurs fonctions) tant que le comportement WebKit n'est pas confirmé par le test de 5 minutes.

2. **Lot « robustesse » : quatre correctifs de 10 à 30 lignes, un commit chacun.**
   - Session illisible : renommer en `.corrupt` au lieu d'écraser (`StateStore.swift`, seulement cela, pas la refonte de format).
   - Crash WebContent : garde-fou de rechargement (Architecte 1.5, version minimale).
   - `closeIfEmpty` épargne les onglets épinglés (Architecte 1.9, 10 minutes).
   - Alertes JS en arrière-plan : pas de `runModal` (Architecte 1.6, version minimale).
   - Pourquoi : chacun corrige un défaut réel et vérifié dans le code, sans conception à valider.

3. **Lot « performance mesurable » : 2 commits, avec une mesure avant/après dans le message de commit.**
   - Suggestions : `@State` calculé sur changement du texte, ids stables (le meilleur constat de Perf).
   - SQLite : WAL + `synchronous=NORMAL` (2 lignes dans `SQLiteDB.swift`).
   - Pourquoi : gain visible sans nouvelle fonction. Les chiffres donnent à l'utilisateur de quoi juger. Ne pas toucher à `media.js`/`core.js` cette nuit : le PiP est la vitrine du produit, et le harnais PiP est le seul garde-fou.

4. **Lot « angles morts qui gênent vraiment » : deux commits.**
   - Authentification HTTP (`didReceive challenge`, ~30 lignes) : bug fonctionnel réel.
   - Passe accessibilité minimale : `accessibilityLabel` sur les boutons-icônes de la barre latérale et de la pastille d'adresse, sans redesign.
   - Optionnel : page d'erreur qui distingue hors ligne / certificat, texte français.
   - Pourquoi : ce sont les trous que tout le conseil a ratés, et ils sont indépendants de la nuit.

5. **Un seul chantier « idée » à l'essai, isolé sur une branche à part et marqué expérimental : le schéma `void://open` (URL scheme).**
   - C'est la meilleure des idées du Visionnaire : petite, testable sans interface, sécurisable par liste blanche http/https.
   - Il reste sur sa propre branche pour que l'utilisateur décide s'il veut la surface d'attaque et la promesse « scriptable ». Ni FTS5, ni App Intents, ni archivage auto, ni EasyList, ni suggestions distantes cette nuit : ce sont des décisions de produit.
   - Dernier commit de la nuit : README mis à jour (nombre de lignes, ✅ seulement pour ce qui est testé automatiquement), avec la liste de ce qui a été fait et de ce qui a été volontairement laissé de côté.

**Pourquoi c'est meilleur au réveil.**
- Le plan des cinq rapports, appliqué tel quel, ferait toucher `CommandBar`, `TabWebDelegate`, `DownloadManager`, `StateStore` et `FeatureSelfTest` par 2 à 4 chantiers chacun. Le résultat serait un gros diff mélangé, difficile à garder ou jeter à la carte.
- Ma version : environ 12 commits de moins de 60 lignes, sans chevauchement de fichiers, ordonnés du plus sûr au plus optionnel. Chaque commit annonce sa vérification (build + auto-test, avant/après pour la perf).
- Aucune nouvelle option de réglage, aucune règle réseau, aucun changement d'identité.
- Chaque décision de produit (sidebar adaptative, mémoire locale, EasyList, suggestions distantes, signature) est laissée à l'utilisateur, avec les rapports comme dossier.
- Règle d'exécution : **ne jamais modifier deux fois le même fichier dans deux chantiers**. `FeatureSelfTest.swift` reçoit ses ajouts dans un fichier séparé par lot (par exemple `FeatureSelfTest+Securite.swift`) pour éviter un fichier de mille lignes de plus.
