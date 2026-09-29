<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Icône de Vedetta">
</p>

<h1 align="center">Vedetta</h1>

<p align="center">
  <b>L'app Mac native et rapide pour vos caméras de surveillance et vos NVR.</b><br>
  Direct, enregistrements avec calendrier et chronologie, export MP4, événements et notifications.<br>
  TP-Link VIGI · Hikvision · Dahua · Reolink · Uniview · tout appareil ONVIF ou RTSP.
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.it.md">Italiano</a></p>

---

Vedetta remplace les lourds logiciels de vidéosurveillance pour Windows (souvent utilisés sur Mac via
Wine/CrossOver) par une app vraiment native : décodage vidéo matériel, interface Liquid Glass pour
macOS 26 et consommation minimale — **16 caméras en direct à 10–13 % de CPU** sur un Mac Apple Silicon.

## Fonctions

- **Direct** — grilles de 1, 4, 6, 8, 9 et 16 cases, pages et rotation automatique, glissez une case sur une
  autre pour échanger les caméras, plein écran, fenêtres séparées pour d'autres écrans, zoom numérique, audio.
  Les petites cases utilisent le flux léger, les cases agrandies la haute qualité ; **captures et enregistrements
  utilisent toujours le flux en qualité maximale**. Noms des caméras toujours / au survol / jamais ; image entière,
  remplie ou étirée (sans couper l'horloge de la caméra).
- **Enregistrements** — calendrier des jours enregistrés, chronologie de 24 h zoomable avec interruptions
  d'enregistrement et événements colorés (mouvement, personnes, véhicules, franchissement de ligne,
  intrusion…), lecture synchronisée jusqu'à 4 caméras, pause, image par image, ±10 s, événement
  précédent/suivant, vitesse si prise en charge. **Raccourcis clavier** (touches simples) et **usage d'une seule
  main** : la molette zoome la chronologie autour du pointeur, des boutons zooment, font défiler et définissent la sélection.
- **Export MP4** — enregistrez n'importe quelle plage ou événement sur le Mac **sans réencodage**, avec ou sans son, avec file
  d'attente, progression, annulation, nouvelle tentative et reprise après redémarrage.
- **Événements et notifications** — liste quotidienne filtrable et notifications macOS ; un clic ramène au moment.
- **PTZ** — joystick, zoom, vitesse et positions enregistrées pour les caméras ONVIF motorisées.
- **Appareils** — détection automatique sur le réseau, configuration en un écran, renommage/masquage des
  canaux, interface web de l'appareil intégrée pour les réglages avancés.
- **Sûre pour les comptes de l'enregistreur** — une seule session par enregistreur, une seule tentative de
  connexion à la fois, aucune connexion tant que l'enregistreur ne répond pas (seulement des vérifications sans
  mot de passe, espacées de plus en plus) ; un mot de passe refusé ou un utilisateur bloqué arrêtent toute
  tentative automatique : le NVR ne bloque pas l'utilisateur et ne fait pas sonner son buzzer à cause de
  Vedetta. Se déconnecter / Changer d'utilisateur depuis le menu ou les Réglages.
- **Efficace et confidentielle** — les flux s'arrêtent quand la fenêtre est masquée ; mots de passe dans le
  trousseau ; aucun compte, aucun cloud, aucune télémétrie.
- **Réglages durables** — enregistrés dès qu'ils changent, lisibles d'une version à l'autre (un fichier abîmé est
  mis de côté et la sauvegarde utilisée), Fichier › Exporter/Importer les réglages (tout sauf les mots de passe).
- **Multilingue** — français, anglais, italien : suit la langue de macOS, modifiable dans les Réglages.

## Appareils pris en charge

| Appareil | Direct | Enregistrements | Événements |
|---|:-:|:-:|:-:|
| NVR **TP-Link VIGI** | ✓ | ✓ | ✓ + notifications |
| **NVR ONVIF de toutes marques** (Hikvision, Dahua, Uniview, Reolink…) | ✓ | ✓ avec ONVIF Profile G | ✓ + notifications |
| NVR **Hikvision / Dahua** sans ONVIF (RTSP) | ✓ | ✓ en choisissant l'heure | – |
| NVR **Reolink / Uniview** sans ONVIF (RTSP) | ✓ | – | – |
| **Caméras ONVIF** de toutes marques, y compris PTZ | ✓ + PTZ | ✓ si elles enregistrent (Profile G) | ✓ |
| Tout flux **RTSP** | ✓ | – | – |

## Protection du compte

Les enregistreurs bloquent un utilisateur (et font souvent sonner leur buzzer) après quelques connexions
échouées. Vedetta est conçue pour ne jamais le provoquer :

- **Une seule session par enregistreur**, partagée par le direct, les enregistrements, les événements et les
  exports. La vidéo ne démarre qu'une fois les identifiants confirmés.
- **Les problèmes réseau ne provoquent jamais de connexion.** Si l'enregistreur ne répond plus, Vedetta le
  vérifie sans envoyer le mot de passe, après 5 s, 10 s, 20 s… jusqu'à 5 minutes, et réutilise la session à son retour.
- **Une tentative à la fois** : les fonctions ne se connectent jamais en parallèle.
- **Mot de passe refusé ou utilisateur bloqué → arrêt complet**, jusqu'à une nouvelle connexion ou l'heure de
  déblocage indiquée par l'enregistreur. Vedetta explique pourquoi et affiche l'écran de connexion.
- **Se déconnecter / Changer d'utilisateur** (menu de l'app, Réglages › Comptes, fiche de l'appareil) ferme la
  vidéo, met fin à la session sur l'enregistreur (seulement en local s'il est injoignable ou l'utilisateur
  bloqué), supprime le mot de passe enregistré et revient à l'écran de connexion.
- **Journal des connexions** avec l'heure, le résultat et le code d'erreur de chaque tentative, sans mot de
  passe : `~/Library/Application Support/Vedetta/Logs/connections.log` (Réglages › Comptes).

**Utilisez un utilisateur dédié** : créez sur l'enregistreur un utilisateur réservé à Vedetta avec uniquement
les droits de direct et de lecture, plutôt que `admin`. Le compte admin et les applications de
l'enregistreur restent ainsi protégés.

## Configuration requise et installation

macOS 26 ou ultérieur, Mac Apple Silicon.

1. Téléchargez `Vedetta-x.y.z-macOS.dmg` depuis la [dernière version](https://github.com/TX-Breaker/vedetta/releases/latest).
2. Faites glisser **Vedetta** dans **Applications**.
3. Si macOS indique qu'il ne peut pas vérifier le développeur : clic droit sur Vedetta → **Ouvrir**
   (ou `xattr -dr com.apple.quarantine /Applications/Vedetta.app`).
4. Autorisez l'accès au **Réseau local** quand macOS le demande.
5. Choisissez quoi connecter, saisissez le mot de passe : c'est prêt.

## Compiler depuis les sources

```bash
git clone https://github.com/TX-Breaker/vedetta.git && cd vedetta
scripts/build-app.sh --install
```

Tests : `swift test` et `scripts/regression.sh` (nécessitent `brew install mediamtx ffmpeg`).
Traductions : `Resources/Localization/strings.tsv` + `python3 scripts/l10n.py`.

## Avertissement

Vedetta est un projet open source indépendant, **ni affilié ni approuvé** par TP-Link, Hikvision, Dahua,
Reolink, Uniview, EZVIZ ou ONVIF. Les marques appartiennent à leurs propriétaires respectifs et ne sont
citées que pour indiquer la compatibilité.

Licence [MIT](LICENSE).
