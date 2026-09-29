# Conseil des agents — nuit du 28 au 29 septembre 2026

Branche : `nuit-conseil`, partie de `glisser-deposer-onglets` @ 40cb9b0. Rien n'a été poussé ni fusionné.
Chaque chantier est un commit indépendant : on peut garder ou jeter chacun séparément (`git cherry-pick <commit>`).

## Comment le conseil a travaillé

**Tour 1 : cinq analyses indépendantes, en lecture seule.** Rapports complets dans [`docs/conseil/`](conseil/).

| Siège | Modèle | Rapport |
|---|---|---|
| Architecte (bugs, cycle de vie, dette) | Opus | [r1-architecte](conseil/r1-architecte.md) |
| Sécurité et vie privée | Opus | [r1-securite](conseil/r1-securite.md) |
| Produit et UX (face à Arc, Safari, Zen, Orion, Dia) | Sonnet | [r1-produit](conseil/r1-produit.md) |
| Performance et WebKit | Sonnet | [r1-perf](conseil/r1-perf.md) |
| Visionnaire et avocat du diable | Sonnet | [r1-vision](conseil/r1-vision.md) |

**Tour 2 : débat.** Un arbitre (Opus) a vérifié dans le code les constats les plus lourds, tranché les désaccords et fixé le plan. Un contradicteur (Sonnet) a attaqué les cinq rapports et relevé leurs angles morts. Rapports : [r2-arbitre](conseil/r2-arbitre.md), [r2-contradicteur](conseil/r2-contradicteur.md).

## Ce que le conseil a conclu

**Le code est sain**, avec un avis unanime :
- pas de cycle de rétention autour des vues web ;
- scripts dans un monde isolé, qu'une page ne peut pas usurper ;
- API privées de WebKit bien protégées ;
- SQL paramétré.

**Les vrais risques** se trouvent dans les états anormaux et à quelques frontières de sécurité :

| Risque | Conséquence |
|---|---|
| Remplissage des mots de passe | Pouvait écrire dans une page d'un autre site |
| Session | Pouvait être perdue avec toutes les connexions |
| Barre d'adresse | Usurpable |
| Onglet en arrière-plan | Pouvait bloquer toute l'app |

**Désaccords tranchés :**
- **Robustesse avant nouveautés.** Le Visionnaire et le Produit poussaient des fonctions visibles (App Intents, `void://`, FTS5, archivage automatique, suggestions distantes). L'arbitre les a reportées : elles ne sont pas testables sans humain, ou bien elles demandent une décision de vie privée ou de produit.
- **Pas d'EasyList cette nuit** : le réseau, la mémoire et la casse de sites ne sont pas mesurés.
- **Pas de récupération automatique des stockages orphelins** : ceux laissés par l'auto-test reviendraient en espaces fantômes. La copie de secours de la session couvre le cas.
- **Le contradicteur a imposé** des commits indépendants, sans deux chantiers sur un même fichier source quand c'est possible, et pas de refactor diffus (concurrence stricte, retrait des singletons).

**Deux identités possibles pour Void**, à trancher par toi :
- « le chrome qui s'évapore » (Produit) ;
- « le navigateur Mac scriptable, qui se souvient localement et range tout seul » (Vision).

## Ce qui a été fait (8 commits + ce document)

Tous les contrôles ajoutés passent par le modèle, le délégué ou le JS, sans clic simulé.

| Commit | Chantier | Vérification |
|---|---|---|
| `4d7bc96` | Auto-test du masquage sur une page locale : example.com ne sert plus de `<h1>`, le test était cassé | — |
| `c31c821` | **Mots de passe verrouillés sur l'origine.** Plus de repli sur le cadre principal. L'hôte vient de l'origine de sécurité du cadre, pas du script. Le JS revérifie l'hôte et le protocole juste avant d'écrire | 3 ✅ |
| `905efc0` | **Session incassable.** Lecture champ par champ (un onglet abîmé est ignoré seul, un format plus récent est relu). Un fichier illisible est renommé `session.corrupt-….json`, jamais écrasé. Copie de secours `session.backup.json` | 3 ✅, dans un dossier temporaire |
| `26a074d` | **Cycle de vie des onglets.** Une alerte JS d'un onglet caché ne bloque plus l'app, et une boucle de dialogues est coupée. Après un plantage de page : veille en arrière-plan, un seul rechargement au premier plan puis un message. Un épinglé n'est jamais supprimé par un téléchargement. ⌘W sur un épinglé en PiP le met vraiment en veille | 5 ✅ + PiP identique à la référence |
| `b835a03` | **Téléchargements et apps externes.** Noms nettoyés (inversion bidirectionnelle, fichiers cachés, 200 caractères), pas de collision entre deux téléchargements, quarantaine garantie. Liens vers d'autres apps : confirmation, refus depuis un cadre intégré ou un script, `smb:`/`ssh:`… refusés | 7 ✅ |
| `a5192ce` | **Barre d'adresse** sur l'URL validée. Cadenas seulement si toute la page est chiffrée | 3 ✅, serveur local qui ne répond jamais |
| `bdfd689` | **Historique et barre de commande.** Base en WAL, titres inchangés non réécrits, ROLLBACK. Suggestions calculées à la frappe et non à chaque survol, identifiants stables | 3 ✅ |
| `cfb7bd0` | Auto-test des trois précédents, plus `-VoidSelfTestOnly` pour lancer une seule section en quelques secondes | — |
| `eecdb82` | **Import** : les copies temporaires des bases de Chrome (historique, mots de passe chiffrés) sont supprimées | vérifié au lancement |

**Constats honnêtes faits en cours de route :**
- **WebKit pose déjà la quarantaine** sur les téléchargements (l'auto-test l'a montré). Le code ajouté n'est qu'une ceinture de sécurité.
- **WebKit publie bien l'URL d'une navigation dès qu'elle commence** (vu dans l'auto-test : `127.0.0.1:8765/banque` en cours de chargement). L'usurpation de la barre d'adresse était donc réelle.
- **Écran verrouillé cette nuit.** Les clics simulés n'arrivent pas quand l'écran est verrouillé. Les contrôles anciens à clics (lien `_blank`, masquage d'élément) échouent pour cette raison ; au dernier passage (73 ✅ / 2 ❌), seul le masquage échouait encore :
  - lien `_blank` ;
  - masquage d'élément (deux contrôles).

  Le test PiP (vidéos en streaming) est dans le même cas. Je l'ai relancé sur le commit de départ dans un worktree séparé : **même tableau**, donc pas de régression. À relancer écran déverrouillé.
- La barre de commande et les dialogues ne se vérifient qu'en partie par l'auto-test. Le rendu (cadenas barré, toast « a voulu afficher une alerte », dialogue « Ouvrir « App » ? ») est à regarder à l'œil.

## À vérifier à la main (5 minutes)

1. Se connecter sur un site où un mot de passe est enregistré → 🔑 → Touch ID → les champs se remplissent (le chemin Touch ID n'est pas testé automatiquement).
2. Cliquer un lien `zoommtg:` ou `vscode:` → dialogue « Ouvrir « … » ? » ; un lien `mailto:` → Mail directement.
3. Relancer Void → la session revient, et `session.backup.json` apparaît dans `~/Library/Application Support/Void/`.
4. Relancer l'auto-test **écran déverrouillé** → attendu : 0 ❌.

## Pas fait, et pourquoi

**Prévu par l'arbitre mais pas atteint cette nuit :**
- palette de commandes `>` dans ⌘L ;
- zoom mémorisé par site ;
- `media.js` plus sobre (cadres vidéo périmés) ;
- reliquats d'hygiène :
  - favicons sans cookies ;
  - échange des listes du bloqueur sans trou ;
  - `fullscreen` réservé aux lecteurs vidéo ;
  - remise à zéro de `loginHost` au changement de page.

  Ce sont les suivants naturels, tous décrits dans [r2-arbitre](conseil/r2-arbitre.md) §3.

**Refusé ou reporté par le conseil** (détail dans [r2-arbitre](conseil/r2-arbitre.md) §4) :
- EasyList ;
- App Intents et `void://` ;
- FTS5 ;
- Foundation Models ;
- archivage automatique ;
- suggestions distantes ;
- changements de l'onboarding ;
- permissions par site ;
- concurrence stricte ;
- extensions ;
- synchronisation, passkeys, cartes bancaires ;
- glisser-déposer dans la barre du haut.

**Angles morts relevés par le contradicteur**, qu'aucun rapport ne traitait :
- accessibilité VoiceOver (17 occurrences seulement dans le code) ;
- authentification HTTP (aucun `didReceive challenge` : sans ce délégué, WebKit ne demande probablement pas d'identifiants aux sites en *Basic Auth* ; à vérifier) ;
- pages d'erreur ;
- distribution : notarisation, mises à jour ;
- mesure de performance sur un Mac modeste.

## Suggestion pour la suite

**Rapides et à fort effet :**
1. Authentification HTTP : ~30 lignes, c'est un vrai bug.
2. Palette `>`.
3. Zoom par site.

**Ensuite**, choisir l'identité (voir « Ce que le conseil a conclu ») : elle décide entre la voie Vision et la voie Produit.
