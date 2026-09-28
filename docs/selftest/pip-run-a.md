# Void — auto-test Picture in Picture

- Date : 2026-09-28T10:45:29Z
- macOS : Version 27.0 (assemblage 26A428)
- WebKit : 22625.1.29.11.27

| Cas | Lecture démarrée | PiP manuel (⌘⇧P) | La vidéo continue en PiP | Sortie du PiP | PiP automatique au changement d'onglet | Vue web gardée attachée à la fenêtre | La vidéo continue (onglet en arrière-plan) | Retour sur l'onglet → sortie du PiP | Plan B : fenêtre flottante affichée | Plan B : la vidéo continue | Plan B : retour de la vue dans l'onglet |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Vidéo HTML5 simple (<video> MP4) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Vidéo HTML5 avec disablepictureinpicture (site qui refuse le PiP) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Repli natif WebKit seul (_togglePictureInPicture) | ✅ | ❌ | ❌ | ✅ |
| Lecteur YouTube dans une iframe sans allow="picture-in-picture" | ❌ |
| Twitch (direct) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

## Vidéo HTML5 simple (<video> MP4)

- ✅ **Lecture démarrée** — hasVideo=true frames=1
- ✅ **PiP manuel (⌘⇧P)** — méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **La vidéo continue en PiP** — currentTime 3.5 s → 6.7 s
- ✅ **Sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **PiP automatique au changement d'onglet** — webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **Vue web gardée attachée à la fenêtre** — superview=WebHostView
- ✅ **La vidéo continue (onglet en arrière-plan)** — currentTime 14.0 s → 17.0 s
- ✅ **Retour sur l'onglet → sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **Plan B : fenêtre flottante affichée** — window=NSPanel level=3
- ✅ **Plan B : la vidéo continue** — currentTime 21.7 s → 24.9 s
- ✅ **Plan B : retour de la vue dans l'onglet** — 

<details><summary>Journal</summary>

```
play() → ok
PASS Lecture démarrée hasVideo=true frames=1
PASS PiP manuel (⌘⇧P) méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS La vidéo continue en PiP currentTime 3.5 s → 6.7 s
PASS Sortie du PiP webkit=false page=false fenêtre-système=non
PASS PiP automatique au changement d'onglet webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS Vue web gardée attachée à la fenêtre superview=WebHostView
PASS La vidéo continue (onglet en arrière-plan) currentTime 14.0 s → 17.0 s
PASS Retour sur l'onglet → sortie du PiP webkit=false page=false fenêtre-système=non
PASS Plan B : fenêtre flottante affichée window=NSPanel level=3
PASS Plan B : la vidéo continue currentTime 21.7 s → 24.9 s
PASS Plan B : retour de la vue dans l'onglet 
```
</details>

## Vidéo HTML5 avec disablepictureinpicture (site qui refuse le PiP)

- ✅ **Lecture démarrée** — hasVideo=true frames=1
- ✅ **PiP manuel (⌘⇧P)** — méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **La vidéo continue en PiP** — currentTime 3.4 s → 6.6 s
- ✅ **Sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **PiP automatique au changement d'onglet** — webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **Vue web gardée attachée à la fenêtre** — superview=WebHostView
- ✅ **La vidéo continue (onglet en arrière-plan)** — currentTime 13.7 s → 16.8 s
- ✅ **Retour sur l'onglet → sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **Plan B : fenêtre flottante affichée** — window=NSPanel level=3
- ✅ **Plan B : la vidéo continue** — currentTime 21.6 s → 24.8 s
- ✅ **Plan B : retour de la vue dans l'onglet** — 

<details><summary>Journal</summary>

```
play() → ok
PASS Lecture démarrée hasVideo=true frames=1
PASS PiP manuel (⌘⇧P) méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS La vidéo continue en PiP currentTime 3.4 s → 6.6 s
PASS Sortie du PiP webkit=false page=false fenêtre-système=non
PASS PiP automatique au changement d'onglet webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS Vue web gardée attachée à la fenêtre superview=WebHostView
PASS La vidéo continue (onglet en arrière-plan) currentTime 13.7 s → 16.8 s
PASS Retour sur l'onglet → sortie du PiP webkit=false page=false fenêtre-système=non
PASS Plan B : fenêtre flottante affichée window=NSPanel level=3
PASS Plan B : la vidéo continue currentTime 21.6 s → 24.8 s
PASS Plan B : retour de la vue dans l'onglet 
```
</details>

## Repli natif WebKit seul (_togglePictureInPicture)

- ✅ **Lecture démarrée** — hasVideo=true frames=1
- ❌ **Toggle natif disponible** — _canTogglePictureInPicture=false
- ❌ **PiP via toggle natif** — webkit=false page=false fenêtre-système=non
- ✅ **Sortie via toggle natif** — webkit=false page=false fenêtre-système=non

<details><summary>Journal</summary>

```
play() → ok
PASS Lecture démarrée hasVideo=true frames=1
FAIL Toggle natif disponible _canTogglePictureInPicture=false
FAIL PiP via toggle natif webkit=false page=false fenêtre-système=non
PASS Sortie via toggle natif webkit=false page=false fenêtre-système=non
```
</details>

## Lecteur YouTube dans une iframe sans allow="picture-in-picture"

- ❌ **Lecture démarrée** — hasVideo=false frames=1

<details><summary>Journal</summary>

```
play() → fail:no-video, pending
clic souris natif → (480, 290)
click → no-button, no-button
play() → fail:no-video, pending
clic souris natif → (480, 290)
click → no-button, no-button
play() → fail:no-video, pending
FAIL Lecture démarrée hasVideo=false frames=1
URL finale : https://void-selftest.example/ · sélectionné=true · fenêtre=true · superview=WebHostView · onglets=1
Vidéos : void-selftest.example: no <video> · iframes=1 · title=Iframe embed | www.youtube-nocookie.com: ready=0 net=0 paused=false err=0 src= · iframes=0 · title=Big Buck Bunny 60fps 4K - Official Blender Foundat
```
</details>

## Twitch (direct)

- ✅ **Lecture démarrée** — hasVideo=true frames=1
- ✅ **PiP manuel (⌘⇧P)** — méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **La vidéo continue en PiP** — currentTime 7.6 s → 10.6 s
- ✅ **Sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **PiP automatique au changement d'onglet** — webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **Vue web gardée attachée à la fenêtre** — superview=WebHostView
- ✅ **La vidéo continue (onglet en arrière-plan)** — currentTime 17.9 s → 20.9 s
- ✅ **Retour sur l'onglet → sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **Plan B : fenêtre flottante affichée** — window=NSPanel level=3
- ✅ **Plan B : la vidéo continue** — currentTime 25.6 s → 28.7 s
- ✅ **Plan B : retour de la vue dans l'onglet** — 

<details><summary>Journal</summary>

```
Twitch : https://www.twitch.tv/nico_la
PASS Lecture démarrée hasVideo=true frames=1
PASS PiP manuel (⌘⇧P) méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS La vidéo continue en PiP currentTime 7.6 s → 10.6 s
PASS Sortie du PiP webkit=false page=false fenêtre-système=non
PASS PiP automatique au changement d'onglet webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS Vue web gardée attachée à la fenêtre superview=WebHostView
PASS La vidéo continue (onglet en arrière-plan) currentTime 17.9 s → 20.9 s
PASS Retour sur l'onglet → sortie du PiP webkit=false page=false fenêtre-système=non
PASS Plan B : fenêtre flottante affichée window=NSPanel level=3
PASS Plan B : la vidéo continue currentTime 25.6 s → 28.7 s
PASS Plan B : retour de la vue dans l'onglet 
```
</details>
