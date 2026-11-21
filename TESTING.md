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

### Étape 2 bis — Amélioration de la précision

Après la première mesure à environ 300 pt (autant que de toujours viser le centre de l'écran) :
- la pupille est maintenant repérée par rapport aux **coins de l'œil** et non à la boîte de l'œil
  (la boîte suivait la paupière et écrasait le signal vertical) ;
- trois modèles possibles, **choisis automatiquement par validation croisée** avec λ :
  deux yeux moyennés, deux yeux + tête, complet (celui du cahier des charges, qui sur-apprend avec 9 points) ;
- le modèle final apprend aussi sur les 5 points de validation (l'erreur affichée reste celle,
  honnête, d'un modèle qui ne les a pas vus) ;
- grille de 9, 16 ou 25 points au choix (Réglages ▸ Regard).

L'ancienne calibration n'est plus lue (mesures différentes) : **recalibrer**.

- [ ] L'écran de résultat montre les 5 cibles (cercles cyan) et les estimations (points rouges) reliées par un trait,
      l'erreur **en x et en y** séparément, le modèle choisi, λ et l'erreur de validation croisée.
- [ ] Refaire une calibration avec 9 points, puis avec 16 points : noter les deux erreurs moyennes.
- [ ] Dans le débogage, en regardant le haut puis le bas de l'écran sans bouger la tête,
      *Pupille G/D (x, y)* : y doit changer (même faiblement, ~0,02 à 0,05).

À rapporter : erreur moyenne, en x, en y, le modèle choisi, et si possible le fichier
`calibration.json` (débogage ▸ *Afficher les données de calibration*). Il ne contient que des nombres
(mesures et points visés), aucune image.

### Étape 2 ter — Stabilité du point de regard

Corrigé : point qui sautille (clignements non filtrés, lissage trop nerveux) et point qui disparaît
sans revenir (valeur NaN qui bloquait les filtres, panneau retiré par le système, caméra figée).

- [ ] Le point tremble nettement moins ; il ne saute plus quand on cligne des yeux.
      *Débogage ▸ Bruit du regard (1 s)* : noter la valeur en fixant un point de l'écran.
- [ ] Il ne disparaît plus : s'il ne peut pas suivre, il reste à sa dernière position en **gris pointillé**
      (« regard perdu »), ou en **rouge pointillé** (« hors écran ») si la prédiction sort de l'écran.
      Dans le débogage, la raison s'affiche (visage non détecté, yeux mal vus, pupille non trouvée…).
- [ ] Il revient dès que le visage est de nouveau bien vu.
- [ ] Mettre le Mac en veille puis le réveiller : le suivi reprend (*Relances caméra* peut augmenter).
- [ ] Si « Yeux fermés ou mal vus » apparaît alors que les yeux sont ouverts : baisser
      *Réglages ▸ Ouverture des yeux minimale*.
- [ ] *Réglages ▸ Lissage ▸ Valeurs par défaut* remet coupure 0,5 Hz, bêta 0,002, médian 5 images,
      fixation 0,15 s / 120 pt.

À rapporter : bruit du regard, fréquence du gris ou du rouge et la raison affichée.

### Étape 2 quater — Déplacements de la tête

Une calibration à une seule position ne sait pas distinguer « l'œil tourne parce que je regarde ailleurs »
de « l'œil tourne parce que ma tête s'est déplacée ». Trois parades :
- **calibration en plusieurs positions** (Réglages ▸ Regard ▸ *Autres positions de la tête*, 2 par défaut) :
  après la grille principale, l'app demande de se décaler (gauche, droite, puis arrière, avant) et montre
  9 points à chaque fois ; le modèle « + tête » apprend alors à corriger ces déplacements ;
- **position de la tête mesurée par les coins des yeux** (bien plus stable que la boîte du visage) ;
- **recentrage** : ⌃⌥R (ou menu ▸ *Recentrer*) affiche un point cyan au centre ; le regarder 1,5 s
  corrige le décalage.

L'ancienne calibration n'est plus lue : **recalibrer**.

- [ ] La calibration enchaîne : grille principale, « Changement de position » (Espace), 9 points,
      etc., puis « Revenez à votre position habituelle », puis les 5 points de vérification.
- [ ] Le modèle choisi est de préférence « Deux yeux moyennés + tête » (affiché sur l'écran de résultat).
- [ ] Après la calibration, se décaler d'une dizaine de centimètres : le point doit rester à peu près juste
      (comparer avec une calibration sans autre position : Réglages ▸ *Aucune*).
- [ ] ⌃⌥R depuis n'importe quelle app : point cyan au centre 1,5 s, puis le point de regard est recalé ;
      *Débogage ▸ Décalage (recentrage)* affiche la correction ; *Effacer* la retire.
- [ ] Le raccourci ⌃⌥R n'est pas tapé dans l'app active.

À rapporter : erreur de validation, modèle choisi, et si le point reste juste après un déplacement.

### Corrections avant l'étape 3
- **Décalage** : sur un écran à encoche, la zone de dessin de la calibration excluait le haut de l'écran,
  donc les points s'affichaient plus bas que les cibles enregistrées (décalage vertical appris par le modèle).
  Corrigé : **recalibrer** pour en profiter. S'il reste un décalage, ⌃⌥R.
- **Regard perdu sans retour** : macOS mettait l'app en sommeil (App Nap) faute de fenêtre visible ;
  l'app le lui interdit maintenant pendant le suivi. La caméra est aussi reconstruite si une relance ne suffit pas,
  et son démarrage est réessayé s'il a échoué.
- L'icône de la barre des menus montre l'état : œil plein = suivi, œil barré = regard perdu ;
  la première ligne du menu en donne la raison.

## Étape 3 — Ciblage

Prérequis : Accessibilité autorisée (écran d'accueil), calibration faite, *Réglages ▸ Ciblage ▸ Surligner l'élément regardé* coché.

- [ ] **Finder** : regarder un bouton de la barre d'outils, un élément de la barre latérale ou un fichier :
      il est entouré d'un rectangle bleu arrondi en moins de 300 ms.
- [ ] **Réglages Système** : idem sur les éléments de la colonne de gauche, les boutons et les interrupteurs.
- [ ] **Safari** : idem sur les liens et les boutons d'une page.
- [ ] Pas de clignotement entre deux boutons voisins quand on regarde entre les deux.
- [ ] Regarder une zone vide (bureau, texte sans lien) : pas de rectangle, seulement le cercle du regard.
- [ ] Le rectangle n'entoure jamais une fenêtre entière ni toute une page web.
- [ ] La vraie souris marche normalement (le surlignage ne bloque aucun clic).
- [ ] *Débogage ▸ Ciblage* : rôle et titre de la cible, nombre d'éléments trouvés, durée de recherche (en ms).
- [ ] Chrome ou une app Electron (si installé) : les liens et boutons sont aussi surlignés.

Réglages utiles : rayon d'accroche (120 pt), délai avant changement (150 ms), taille max. d'une cible.

À rapporter : apps où ça marche ou pas, durée de recherche typique, et tout clignotement.

### Étape 3 bis — Cible plus « collante » et apprentissage par les clics

- **Marge d'accroche** (40 pt) : la cible reste surlignée tant que le regard reste dans la cible élargie
  de cette marge, même si un voisin devient plus proche ou si une recherche la manque.
  Réglages ▸ Ciblage ▸ *Marge d'accroche* : l'augmenter si la cible saute encore.
- **Apprentissage continu** : chaque vrai clic de souris (écouté, jamais intercepté) sert de point de
  calibration. Le regard estimé juste avant le clic est comparé à l'endroit cliqué ; les 5 derniers clics
  fixent le décalage, et le modèle est réappris tous les 20 clics. Un clic à plus de 300 pt du regard estimé
  est ignoré (on ne regardait sans doute pas ce qu'on cliquait).

- [ ] Utiliser le Mac normalement à la souris quelques minutes, en regardant ce qu'on clique :
      *Débogage ▸ Clics appris / ignorés* augmente, *Écart au dernier clic* diminue.
- [ ] Le décalage visible du cercle se réduit au fil des clics.
- [ ] Se décaler sur sa chaise puis ⌃⌥R : le décalage est corrigé d'un coup (historique des clics remis à zéro).
- [ ] La cible ne saute plus quand le regard tremble à côté d'elle.

À rapporter : écart au dernier clic au début et après quelques minutes, nombre de clics ignorés.

### Étape 3 ter — Exercice d'entraînement

Menu ▸ **Entraînement (cliquer en regardant)…** (ou bouton dans le débogage). Nécessite une calibration.

- [ ] Plein écran sombre, pointeur visible. Espace pour commencer.
- [ ] 30 cibles orange apparaissent une à une, réparties sur tout l'écran. Regarder la cible, puis la cliquer
      en continuant à la regarder. Un clic à côté (plus de 45 pt) est ignoré.
- [ ] Après chaque clic : un point rouge montre où le modèle pensait que l'on regardait, avec l'écart en points.
- [ ] En bas : progression et écart moyen. Se décaler un peu sur sa chaise de temps en temps pendant l'exercice.
- [ ] À la fin : « Apprentissage… », puis l'écart moyen pendant l'exercice (ancien modèle) et l'erreur estimée
      du nouveau modèle. Entrée ferme ; Échap annule à tout moment sans rien apprendre.
- [ ] Après l'exercice, le cercle du regard est mieux placé. Refaire un exercice : l'écart moyen pendant
      l'exercice doit baisser par rapport au premier.
- [ ] Les mesures s'accumulent d'un exercice à l'autre et survivent à un redémarrage
      (*Débogage ▸ Clics appris* : nombre de mesures).

À rapporter : écart moyen du 1er et du 2e exercice, erreur estimée du nouveau modèle.
