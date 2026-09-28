# Void — auto-test Picture in Picture

- Date : 2026-09-28T10:48:16Z
- macOS : Version 27.0 (assemblage 26A428)
- WebKit : 22625.1.29.11.27

| Cas | Lecture démarrée | PiP manuel (⌘⇧P) | La vidéo continue en PiP | Sortie du PiP | PiP automatique au changement d'onglet | Vue web gardée attachée à la fenêtre | La vidéo continue (onglet en arrière-plan) | Retour sur l'onglet → sortie du PiP | Plan B : fenêtre flottante affichée | Plan B : la vidéo continue | Plan B : retour de la vue dans l'onglet |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Lecteur YouTube dans une iframe sans allow="picture-in-picture" | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| YouTube (page de lecture) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Vimeo (streaming HLS) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Dailymotion (streaming HLS) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

## Lecteur YouTube dans une iframe sans allow="picture-in-picture"

- ✅ **Lecture démarrée** — hasVideo=true frames=1
- ✅ **PiP manuel (⌘⇧P)** — méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **La vidéo continue en PiP** — currentTime 4.2 s → 7.3 s
- ✅ **Sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **PiP automatique au changement d'onglet** — webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **Vue web gardée attachée à la fenêtre** — superview=WebHostView
- ✅ **La vidéo continue (onglet en arrière-plan)** — currentTime 14.5 s → 17.6 s
- ✅ **Retour sur l'onglet → sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **Plan B : fenêtre flottante affichée** — window=NSPanel level=3
- ✅ **Plan B : la vidéo continue** — currentTime 22.3 s → 25.5 s
- ✅ **Plan B : retour de la vue dans l'onglet** — 

<details><summary>Journal</summary>

```
play() → fail:no-video, pending
clic souris natif → (480, 270)
PASS Lecture démarrée hasVideo=true frames=1
PASS PiP manuel (⌘⇧P) méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS La vidéo continue en PiP currentTime 4.2 s → 7.3 s
PASS Sortie du PiP webkit=false page=false fenêtre-système=non
PASS PiP automatique au changement d'onglet webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS Vue web gardée attachée à la fenêtre superview=WebHostView
PASS La vidéo continue (onglet en arrière-plan) currentTime 14.5 s → 17.6 s
PASS Retour sur l'onglet → sortie du PiP webkit=false page=false fenêtre-système=non
PASS Plan B : fenêtre flottante affichée window=NSPanel level=3
PASS Plan B : la vidéo continue currentTime 22.3 s → 25.5 s
PASS Plan B : retour de la vue dans l'onglet 
```
</details>

## YouTube (page de lecture)

- ✅ **Lecture démarrée** — hasVideo=true frames=2
- ✅ **PiP manuel (⌘⇧P)** — méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **La vidéo continue en PiP** — currentTime 4.9 s → 7.9 s
- ✅ **Sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **PiP automatique au changement d'onglet** — webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **Vue web gardée attachée à la fenêtre** — superview=WebHostView
- ✅ **La vidéo continue (onglet en arrière-plan)** — currentTime 15.2 s → 18.3 s
- ✅ **Retour sur l'onglet → sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **Plan B : fenêtre flottante affichée** — window=NSPanel level=3
- ✅ **Plan B : la vidéo continue** — currentTime 22.9 s → 26.1 s
- ✅ **Plan B : retour de la vue dans l'onglet** — 

<details><summary>Journal</summary>

```
PASS Lecture démarrée hasVideo=true frames=2
PASS PiP manuel (⌘⇧P) méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS La vidéo continue en PiP currentTime 4.9 s → 7.9 s
PASS Sortie du PiP webkit=false page=false fenêtre-système=non
PASS PiP automatique au changement d'onglet webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS Vue web gardée attachée à la fenêtre superview=WebHostView
PASS La vidéo continue (onglet en arrière-plan) currentTime 15.2 s → 18.3 s
PASS Retour sur l'onglet → sortie du PiP webkit=false page=false fenêtre-système=non
PASS Plan B : fenêtre flottante affichée window=NSPanel level=3
PASS Plan B : la vidéo continue currentTime 22.9 s → 26.1 s
PASS Plan B : retour de la vue dans l'onglet 
```
</details>

## Vimeo (streaming HLS)

- ✅ **Lecture démarrée** — hasVideo=true frames=1
- ✅ **PiP manuel (⌘⇧P)** — méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **La vidéo continue en PiP** — currentTime 3.5 s → 6.6 s
- ✅ **Sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **PiP automatique au changement d'onglet** — webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **Vue web gardée attachée à la fenêtre** — superview=WebHostView
- ✅ **La vidéo continue (onglet en arrière-plan)** — currentTime 13.8 s → 17.0 s
- ✅ **Retour sur l'onglet → sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **Plan B : fenêtre flottante affichée** — window=NSPanel level=3
- ✅ **Plan B : la vidéo continue** — currentTime 21.7 s → 24.8 s
- ✅ **Plan B : retour de la vue dans l'onglet** — 

<details><summary>Journal</summary>

```
play() → ok
PASS Lecture démarrée hasVideo=true frames=1
PASS PiP manuel (⌘⇧P) méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS La vidéo continue en PiP currentTime 3.5 s → 6.6 s
PASS Sortie du PiP webkit=false page=false fenêtre-système=non
PASS PiP automatique au changement d'onglet webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS Vue web gardée attachée à la fenêtre superview=WebHostView
PASS La vidéo continue (onglet en arrière-plan) currentTime 13.8 s → 17.0 s
PASS Retour sur l'onglet → sortie du PiP webkit=false page=false fenêtre-système=non
PASS Plan B : fenêtre flottante affichée window=NSPanel level=3
PASS Plan B : la vidéo continue currentTime 21.7 s → 24.8 s
PASS Plan B : retour de la vue dans l'onglet 
```
</details>

## Dailymotion (streaming HLS)

- ✅ **Lecture démarrée** — hasVideo=true frames=1
- ✅ **PiP manuel (⌘⇧P)** — méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **La vidéo continue en PiP** — currentTime 4.7 s → 7.9 s
- ✅ **Sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **PiP automatique au changement d'onglet** — webkit=false page=true fenêtre-système=Picture in Picture(851×460)
- ✅ **Vue web gardée attachée à la fenêtre** — superview=WebHostView
- ✅ **La vidéo continue (onglet en arrière-plan)** — currentTime 15.2 s → 18.2 s
- ✅ **Retour sur l'onglet → sortie du PiP** — webkit=false page=false fenêtre-système=non
- ✅ **Plan B : fenêtre flottante affichée** — window=NSPanel level=3
- ✅ **Plan B : la vidéo continue** — currentTime 22.9 s → 26.1 s
- ✅ **Plan B : retour de la vue dans l'onglet** — 

<details><summary>Journal</summary>

```
PASS Lecture démarrée hasVideo=true frames=1
PASS PiP manuel (⌘⇧P) méthode=API standard (requestPictureInPicture) · webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS La vidéo continue en PiP currentTime 4.7 s → 7.9 s
PASS Sortie du PiP webkit=false page=false fenêtre-système=non
PASS PiP automatique au changement d'onglet webkit=false page=true fenêtre-système=Picture in Picture(851×460)
PASS Vue web gardée attachée à la fenêtre superview=WebHostView
PASS La vidéo continue (onglet en arrière-plan) currentTime 15.2 s → 18.2 s
PASS Retour sur l'onglet → sortie du PiP webkit=false page=false fenêtre-système=non
PASS Plan B : fenêtre flottante affichée window=NSPanel level=3
PASS Plan B : la vidéo continue currentTime 22.9 s → 26.1 s
PASS Plan B : retour de la vue dans l'onglet 
```
</details>
