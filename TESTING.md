# Vérifications manuelles

Ce qui touche à la caméra, aux autorisations et aux clics se vérifie à la main sur le Mac.
Après chaque étape : lancer l'app (⌘R dans Xcode) et cocher les cases ci-dessous.

## Étape 1 — Squelette et autorisations

Préparation : choisir la Team de signature des deux cibles (voir README), puis

```bash
xcodebuild -project SourisBeauRegard.xcodeproj -scheme SourisBeauRegard -configuration Debug build
```

```bash
xcodebuild test -project SourisBeauRegard.xcodeproj -scheme SourisBeauRegard -destination 'platform=macOS'
```

### Barre des menus
- [ ] Une icône **œil** apparaît dans la barre des menus ; **aucune icône** dans le Dock.
- [ ] Le menu contient : *Caméra : arrêtée*, *Autorisations…*, *Fenêtre de débogage…*, *Réglages…*, *Quitter*.
- [ ] *Réglages…* ouvre une petite fenêtre au premier plan (trois curseurs de seuils).

### Écran d'accueil des autorisations
- [ ] Au premier lancement, l'écran d'accueil s'ouvre tout seul, au premier plan.
- [ ] Trois lignes : Caméra, Accessibilité, Surveillance de l'entrée (facultative), chacune avec son état.
- [ ] *Demander* sur Caméra affiche la demande système avec le texte français ; après accord l'état passe à « Autorisé ».
- [ ] *Demander* sur Accessibilité affiche l'invite système ; après avoir coché l'app dans les Réglages,
      l'état passe à « Autorisé » en une seconde environ, sans relancer l'app.
- [ ] *Réglages…* sur chaque ligne ouvre le **bon** panneau des Réglages Système.
- [ ] *Continuer* ferme la fenêtre. Au lancement suivant, elle ne se rouvre pas si Caméra et Accessibilité sont autorisées.
- [ ] Après un nouveau build (⌘R), l'Accessibilité est toujours « Autorisé » (signature stable).

### Fenêtre de débogage
- [ ] Menu ▸ *Fenêtre de débogage…* : l'image de la caméra s'affiche, en miroir (case à décocher pour l'image brute).
- [ ] Le voyant vert de la caméra s'allume ; le menu indique *Caméra : active*.
- [ ] Boîte verte autour du visage, contours jaunes (visage, sourcils, yeux, nez, lèvres), **points rouges sur les pupilles**,
      boîtes cyan autour des yeux. Tout suit le visage sans décalage visible, y compris en miroir.
- [ ] **Images par seconde ≥ 25** (panneau de droite) ; durée d'analyse Vision affichée en ms.
- [ ] Résolution affichée : 1920 × 1080 (ou 1280 × 720 selon la caméra).
- [ ] Lacet / tangage / roulis changent quand on tourne, hoche ou penche la tête.
- [ ] Fermer un œil fait baisser son ouverture ; les deux fermés → avertissement « Yeux peu visibles ».
- [ ] Sortir du champ → « Aucun visage détecté » ; à contre-jour → « Confiance de détection faible » (si cela se produit).
- [ ] Fermer la fenêtre de débogage éteint la caméra (voyant éteint, menu *Caméra : arrêtée*).

À rapporter : le nombre d'images par seconde observé, la durée d'analyse Vision, la résolution, et tout ce qui ne
correspond pas à la liste ci-dessus (avec le message d'erreur Xcode éventuel).

## Étape 2 — Mesures et calibration

Build et tests comme à l'étape 1 (les deux commandes `xcodebuild`).

### Mesures (fenêtre de débogage)
- [ ] Une **croix rose** (pupille « image ») apparaît sur chaque pupille, à côté du point rouge (pupille Vision).
- [ ] En regardant à gauche puis à droite sans bouger la tête, *Pupille G/D (x, y)* changent nettement
      (de l'ordre de 0,1 ou plus) ; idem haut / bas pour y, plus faiblement.
- [ ] Le sélecteur *Pupille* bascule entre Vision et Image ; noter laquelle bouge le plus proprement.
- [ ] *Part sombre* : si la croix rose saute vers les cils ou le coin de l'œil, essayer une autre valeur.
- [ ] Images par seconde toujours ≥ 25 (les deux méthodes tournent à chaque image).

### Calibration
- [ ] Menu ▸ *Calibrer…* : plein écran sombre sur l'écran du pointeur, pointeur caché, consignes affichées.
- [ ] Espace : 9 points blancs aux bords (8 %) et au centre, dans un ordre aléatoire, chacun rétrécit en 1,5 s.
      En bas, le compteur de mesures augmente (environ 20 par point).
- [ ] Puis 5 points cyan de vérification.
- [ ] L'écran de résultat affiche l'**erreur moyenne et maximale en points**.
      **Objectif : moyenne sous 150 points**, assis à 50–70 cm, visage bien éclairé.
- [ ] R recommence, Échap annule à tout moment (le pointeur réapparaît), Entrée garde la calibration.
- [ ] Le menu affiche ensuite « Calibration : erreur moyenne … pt ».

### Point de regard
- [ ] Après calibration, un cercle orange suit le regard par-dessus toutes les fenêtres,
      y compris une app en plein écran et sur un autre bureau (Mission Control).
- [ ] Il devient vert et se stabilise quand on fixe un endroit.
- [ ] La souris réelle fonctionne normalement : le cercle ne bloque aucun clic.
- [ ] Menu ▸ *Afficher le point de regard* le masque / l'affiche ; *Suivre le regard* coupe la caméra
      (si la fenêtre de débogage est fermée).
- [ ] Quitter et relancer l'app : la calibration est rechargée, le cercle revient sans recalibrer.
- [ ] Dans *Réglages…* ou le débogage, déplacer λ : l'erreur de validation affichée change (sans recalibrer).

À rapporter : l'erreur moyenne et maximale obtenue (avec la méthode de pupille utilisée, et si possible
avec les deux), la distance à l'écran, l'éclairage, et le comportement du cercle (tremblement, retard).
