# Void — compte rendu Picture in Picture

Testé le 28/09/2026 sur macOS 27.0 (26A428), WebKit 22625.1.29, Mac Apple silicon.
Rapports bruts et captures : [`docs/selftest/`](selftest/).

## 1. Causes du PiP cassé examinées

| Cause probable | Constat dans Void | Traitement |
|---|---|---|
| Entitlements / App Sandbox | Le PiP de WebKit ne dépend d'aucun entitlement. Void n'est pas sandboxé (pour l'import d'autres navigateurs), Hardened Runtime activé. | Aucun entitlement requis ; vérifié par le test (la fenêtre système « Picture in Picture » apparaît). |
| `WKWebViewConfiguration` | `allowsInlineMediaPlayback` et `allowsPictureInPictureMediaPlayback` n'existent **que sur iOS** (vérifié dans le SDK macOS 27). Sur macOS, la préférence interne `_allowsPictureInPictureMediaPlayback` vaut YES par défaut. | Void la force à YES via KVC, avec vérification `responds(to:)`. Plein écran d'élément activé (`isElementFullscreenEnabled`), `mediaTypesRequiringUserActionForPlayback = []`. |
| User agent | Sans « Version/x Safari/x », certains lecteurs servent une version dégradée. | Suffixe Safari ajouté (version lue depuis Safari installé). |
| Iframes sans `allow="picture-in-picture"` | Fréquent pour les lecteurs intégrés. | `core.js` ajoute `picture-in-picture; fullscreen` à chaque iframe dès son insertion. Testé avec un embed YouTube sans l'attribut : ✅. |
| Exigence d'un geste utilisateur | `requestPictureInPicture()` refuse sans geste. | Les appels passent par `callAsyncJavaScript`, que WebKit exécute **avec** un geste utilisateur : ⌘⇧P, le bouton et le PiP automatique fonctionnent. |
| Vue web détachée/masquée au changement d'onglet | Cause n° 1 des PiP qui se ferment ou des vidéos qui se mettent en pause : WebKit considère une vue retirée de la fenêtre ou `isHidden` comme invisible. | `WebHost` **garde attachées** (sous l'onglet actif) les vues web qui lisent une vidéo ou sont en PiP. Testé : lecture continue en arrière-plan ✅. |
| Changements de mode de présentation non gérés | L'app ne savait pas quand le PiP se fermait. | `media.js` écoute `enter/leavepictureinpicture` et `webkitpresentationmodechanged` ; « retour à l'onglet » depuis la fenêtre PiP resélectionne l'onglet. |
| Attribut `disablepictureinpicture` | Certains sites désactivent le PiP. | Levé à la demande explicite de l'utilisateur. Testé ✅. |
| Promesse JS qui ne se résout jamais | Trouvé pendant les tests : un `await` sur une promesse de la page bloquait tout. | Tous les appels JS ont un délai maximum (5 s). |

## 2. Mécanisme retenu

1. **PiP manuel (⌘⇧P, bouton ▣ dans la barre d'adresse, menu contextuel)** : `media.js` (monde JS isolé, toutes les frames) repère la vidéo en lecture ou la plus grande, dans la page et ses iframes (y compris cross-origin), puis `requestPictureInPicture()`, puis `webkitSetPresentationMode('picture-in-picture')`.
2. **Repli WebKit natif** `_togglePictureInPicture` (mécanisme du menu PiP de Safari) : utilisé seulement s'il se déclare disponible.
3. **Plan B — lecteur flottant Void** : la vue web de l'onglet passe dans un petit panneau toujours au premier plan (tous les Spaces, au-dessus du plein écran), la vidéo remplit le panneau. Bouton ↖ pour revenir à l'onglet.
4. **PiP automatique** : en quittant un onglet (ou un espace) dont la vidéo joue **avec le son**, PiP automatique ; au retour sur l'onglet, sortie du PiP. Désactivable (Réglages → Général). Les aperçus muets (survol YouTube) sont volontairement exclus.

## 3. Résultats de l'auto-test (tests réels, pas de simulation)

L'auto-test (`-VoidSelfTest pip`, build Debug) pilote les vrais chemins de code, avec un clic souris natif pour lancer les lecteurs et la détection de la fenêtre système « Picture in Picture ».

| Cas | Lecture | PiP manuel | Vidéo continue en PiP | Sortie | PiP auto (changement d'onglet) | Vue gardée attachée | Lecture continue en arrière-plan | Retour → sortie PiP | Plan B affiché | Plan B lit | Plan B retour |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Vidéo HTML5 simple (MP4) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| HTML5 avec `disablepictureinpicture` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| YouTube dans une iframe sans `allow` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **YouTube** (page de lecture) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Vimeo** (streaming HLS) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Dailymotion** (iframe cross-origin) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Twitch** (direct) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

Dans tous les cas le PiP est obtenu par l'**API standard** (`requestPictureInPicture`), et la fenêtre système « Picture in Picture » (≈ 851×460 px) est bien détectée à l'écran.

Repli WebKit natif seul (`_togglePictureInPicture`) : ❌ — `_canTogglePictureInPicture` renvoie `false` sur ce WebKit pour une vidéo lancée par script. Ce niveau n'est donc pas exploitable aujourd'hui ; il reste inoffensif (non appelé s'il se déclare indisponible), le plan B prend le relais.

Note de transparence : pendant la mise au point, l'iframe YouTube a échoué une fois (clic de test mal centré dans le harnais, corrigé), et un bug réel a été trouvé et corrigé : la vue web d'un onglet pouvait rester hors de la fenêtre après la fermeture du seul onglet (mise à jour SwiftUI manquée) — `WebHost` observe désormais directement le modèle.

## 4. Limites connues

- **DRM (Netflix, Disney+, Canal+… en FairPlay/EME)** : non testé (nécessite des comptes). Safari gère le PiP des contenus FairPlay, mais un WKWebView tiers peut se voir refuser la lecture DRM ou le PiP selon le service. Le plan B (lecteur flottant) fonctionne en principe avec tout contenu lisible dans Void, puisque c'est la page elle-même qui est affichée.
- **Sites qui recréent l'attribut `disablePictureInPicture` en boucle ou détournent l'API** : le PiP natif peut échouer → plan B.
- **Plan B** : fenêtre Void (pas la fenêtre système) ; les commandes sont celles de la vidéo HTML5 ; la page reste active (plus gourmand qu'un vrai PiP). Les iframes cross-origin dont la vidéo est plus petite que l'iframe peuvent laisser des bandes.
- **« Retour à l'onglet » depuis la fenêtre PiP** : détecté par heuristique (la vidéo continue ⇒ retour ; elle se met en pause ⇒ fermeture).
- **PiP automatique** ne se déclenche pas au passage à une autre application (seulement changement d'onglet/espace), par choix.
- Les consentements cookies (UE) et les « clic pour lire » des lecteurs intégrés sont gérés **par le harnais de test uniquement**, pas par l'app.

## 5. Checklist de test manuel (5 minutes)

1. Ouvrir `https://www.youtube.com/watch?v=aqz-KE-bpKQ`, lancer la vidéo avec le son.
2. **⌘⇧P** → la fenêtre PiP système apparaît, la vidéo continue. **⌘⇧P** à nouveau → retour dans la page.
3. Vidéo en lecture, **⌘T** puis ouvrir un autre site → PiP automatique, le son continue. Revenir sur l'onglet YouTube → le PiP se ferme, la vidéo reste en lecture dans la page.
4. En PiP, cliquer sur « revenir » dans la fenêtre PiP (icône ↖) → Void revient au premier plan sur le bon onglet.
5. En PiP, fermer avec ✕ → la vidéo se met en pause, l'onglet courant ne change pas.
6. Vimeo ou Dailymotion (lecteur en iframe) : répéter 2 et 3.
7. Twitch en direct : répéter 2 et 3.
8. Changer d'**espace** (balayage à deux doigts sur la barre latérale, ou ⌃⌘→) avec une vidéo en lecture → PiP automatique.
9. Réglages → Général → décocher « Picture in Picture automatique » → refaire 3 : pas de PiP, mais le son continue en arrière-plan.
10. Page avec une vidéo HTML5 simple (ex. `https://media.w3.org/2010/05/sintel/trailer.mp4`) → ⌘⇧P.
11. Clic droit sur une page vidéo → « Picture in Picture ».
12. Plan B : sur un site qui refuse le PiP, ⌘⇧P affiche « lecteur flottant Void » ; la fenêtre flottante reste au-dessus des autres apps ; ↖ ramène la vidéo dans l'onglet.

## 6. Relancer l'auto-test

```bash
xcodebuild -project Void.xcodeproj -scheme Void -configuration Debug -derivedDataPath build/DerivedData build
build/DerivedData/Build/Products/Debug/Void.app/Contents/MacOS/Void -VoidSelfTest pip -VoidSelfTestOut /tmp/void-pip.md
```

Options : `-VoidSelfTestOnly html5,disabled,native,iframe,youtube,vimeo,dailymotion,twitch`. Une fenêtre Void s'ouvre et lit des vidéos à 2 % du volume (≈ 1 min par cas). L'auto-test utilise un espace jetable et des onglets privés ; il ne lit ni n'écrit la session de l'utilisateur.
