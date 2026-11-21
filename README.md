# Souris beau regard

App macOS de barre des menus qui remplace la souris par le regard, sur le modèle du Vision Pro :
on **regarde** un élément pour le viser, on **appuie sur une touche** pour cliquer.
Tout tourne en local avec la webcam du Mac, sans réseau, et aucune image n'est enregistrée.

Une webcam donne un regard imprécis (2 à 4 cm d'erreur à l'écran). L'app ne vise donc pas un pixel
mais l'**élément cliquable le plus proche** du regard, trouvé grâce à l'API d'accessibilité de macOS.

> État : **étape 4 / 6** — calibration, point de regard, surlignage de l'élément regardé (accessibilité),
> clic au clavier (Option droite), apprentissage continu par les clics de souris.
> Voir `TESTING.md` pour les vérifications de chaque étape.

## Prérequis

- macOS 14 ou plus, Mac Apple Silicon, webcam intégrée ou externe.
- Xcode 16 ou plus (le projet utilise des dossiers synchronisés : un fichier `.swift` ajouté dans
  `SourisBeauRegard/` est compilé sans toucher au `.pbxproj`).
- Un compte Apple Developer (gratuit ou payant) pour signer avec l'équipe « Apple Development ».

## Compiler

1. Ouvrir `SourisBeauRegard.xcodeproj`.
2. Cible **SourisBeauRegard** → onglet *Signing & Capabilities* → choisir votre **Team**.
   Faites de même pour la cible **SourisBeauRegardTests**.
   L'identifiant de bundle est fixe : `fr.sourisbeauregard.SourisBeauRegard` (changez-le une fois
   si Xcode le refuse, puis ne le changez plus).
   *Pourquoi* : macOS attache les autorisations (Accessibilité surtout) à la signature. Une équipe et
   un identifiant fixes évitent de devoir tout réautoriser après chaque build.
3. Compiler et tester en ligne de commande :

```bash
xcodebuild -project SourisBeauRegard.xcodeproj -scheme SourisBeauRegard -configuration Debug build
```

```bash
xcodebuild test -project SourisBeauRegard.xcodeproj -scheme SourisBeauRegard -destination 'platform=macOS'
```

## Lancer

Dans Xcode : **⌘R**. L'app n'a pas d'icône dans le Dock (`LSUIElement`) : cherchez l'**œil** dans la
barre des menus. Au premier lancement, l'écran d'accueil des autorisations s'ouvre.

## Autoriser

L'écran d'accueil (menu ▸ *Autorisations…*) montre l'état de chaque autorisation, avec un bouton
pour la demander et un autre pour ouvrir le bon panneau des Réglages Système :

| Autorisation | Pourquoi | Indispensable |
|---|---|---|
| Caméra | suivre le regard | oui |
| Accessibilité | lire les éléments à l'écran, envoyer les clics, intercepter la touche | oui |
| Surveillance de l'entrée | parfois exigée par macOS pour intercepter le clavier | non |

Si l'Accessibilité semble perdue après un build (case cochée mais l'app dit « Non autorisé ») :

```bash
tccutil reset Accessibility fr.sourisbeauregard.SourisBeauRegard
```

puis relancer l'app et réautoriser.

## Calibrer

1. Asseyez-vous à 50–70 cm de l'écran, visage bien éclairé de face (pas de fenêtre derrière vous).
2. Placez le pointeur sur l'écran à calibrer, puis menu ▸ **Calibrer…**.
3. Espace pour commencer. Suivez des yeux chaque point blanc jusqu'à ce qu'il ait rétréci
   (9 points dans un ordre aléatoire), puis les 5 points cyan de vérification. Gardez la tête immobile.
4. L'erreur moyenne et maximale s'affiche en points écran (objectif : moins de 150).
   **Entrée** garde la calibration, **R** recommence, **Échap** annule.

Par défaut, la calibration demande aussi 2 autres positions de la tête (décalé à gauche, à droite ;
jusqu'à 4 avec arrière et avant) : le modèle apprend ainsi à corriger les déplacements sur la chaise.
Après un déplacement, **⌃⌥R** (ou menu ▸ *Recentrer*) : regarder le point cyan au centre 1,5 s recale le regard.

Le modèle (deux yeux moyennés, + tête, ou complet) et λ sont choisis automatiquement par
validation croisée ; on peut les imposer dans les réglages, comme le nombre de points (9, 16 ou 25).

La calibration est enregistrée dans
`~/Library/Application Support/SourisBeauRegard/calibration.json` et rechargée au lancement.
Elle contient les mesures brutes : changer λ (réglages ou fenêtre de débogage) refait le calcul
et l'erreur de validation sans recalibrer. Changer de méthode de pupille demande une nouvelle calibration,
comme une mise à jour qui change les mesures (l'ancien fichier est alors ignoré).

Le point de regard (cercle orange, vert pendant une fixation) s'affiche par-dessus tout ;
menu ▸ *Afficher le point de regard* pour le masquer, *Suivre le regard* pour mettre en pause.

## Architecture

```
SourisBeauRegard/
├── App/          point d'entrée (MenuBarExtra + Settings), état central, réglages
├── Permissions/  état des autorisations, écran d'accueil
├── Capture/      AVCaptureSession + analyse Vision sur une file dédiée
├── Vision/       FaceAnalyzer (repères), PupilLocator (Vision / zone sombre), qualité
├── Gaze/         GazeFeatures, RidgeRegression, CalibrationModel/Plan/Session,
│                 OneEuroFilter, FixationDetector, GazeEngine
├── Targeting/    AXTargetFinder (grille 5×5 autour du regard), choix de la cible avec hystérésis
├── Input/        ClickSource, KeyClickSource (CGEventTap), ClickLogic, MouseController, raccourcis globaux
├── Geometry/     CoordinateSpaces : seul module de conversion Vision / AppKit / Quartz
└── UI/           débogage, réglages, surlignage (OverlayWindow), calibration plein écran
SourisBeauRegardTests/   tests de la logique pure
```

Principes :
- la chaîne du regard (caméra → mesures → calibration → lissage → cible) tourne à chaque image ;
  une source de clic séparée déclenche l'action sur la cible, seulement à l'appui de la touche ;
- la logique pure (conversions, filtres, régression, choix de cible) est dans des types sans
  AppKit ni AVFoundation, et testée ;
- capture et Vision dans `CameraService`, sur sa propre file, résultats republiés sur `@MainActor` ;
- aucune dépendance externe, aucun appel réseau.

## Ciblage

Le regard ne vise pas un pixel mais l'élément cliquable le plus proche : l'app interroge l'accessibilité
de macOS sur une grille de 5 × 5 points dans le rayon d'accroche (120 pt par défaut), remonte chaque
élément touché jusqu'au premier ancêtre cliquable (bouton, lien, case, menu, champ, cellule, ou tout
élément qui propose « AXPress »), et garde celui dont le centre est le plus proche du regard.
On ne change de cible que si la nouvelle reste la plus proche 150 ms. Pour Chrome et les apps Electron,
l'app active leur accessibilité (`AXManualAccessibility`).

## Cliquer

Regarder un élément (il se surligne), puis appuyer sur **Option droite** : le clic part au centre de
l'élément retenu environ 120 ms avant l'appui. Touche maintenue pendant que le regard se déplace :
glisser-déposer. Deux appuis rapides : double-clic. Contrôle + touche : clic droit. La touche est avalée
(elle ne tape rien) seulement quand le suivi est actif. La souris réelle n'est jamais interceptée.

**Arrêt d'urgence : ⌃⌥⌘Échap** (coupe l'interception de la touche, relâche la souris, éteint la caméra).
