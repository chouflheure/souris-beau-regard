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
