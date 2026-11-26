# Motion du ruban

Le ruban de Murmure en 3D (Three.js), rendu en vidéo avec HyperFrames, via le dépôt
[motion-design-claude-code](https://github.com/cblain100-prog/motion-design-claude-code) installé sur le VPS
(`~/motion-design-claude-code`).

- `ribbon3d.js` : le modèle partagé (forme, couleurs, pliage, boucle de 1,5 s). À copier dans chaque projet.
- `ruban/` : le ruban seul, 1080 × 1080, pour regarder le mouvement.
- `encoche/` : la bande de dictée sous l'encoche, zoomée 3 fois, à la vitesse réelle.
- `ruban-frames/` : la boucle cadrée serré (480 × 300, fond transparent), rendue en images pour l'app et le site.

Pour refaire les images de l'app et du site :

```bash
# Sur le VPS, chaque dossier copié à la racine du dépôt motion, avec ribbon3d.js à côté de index.html
cd ~/motion-design-claude-code/murmure-ruban-frames
npx hyperframes render --format png-sequence --fps 30 -o renders/frames
# En local : recadrer, ranger en grille 9 × 5, compresser
ffmpeg -framerate 30 -start_number 1 -i frames/frame_%06d.png -vf "crop=436:276:44:8,tile=9x5" -frames:v 1 -pix_fmt rgba sprite.png
cwebp -q 86 -alpha_q 95 -m 6 sprite.png -o Resources/RibbonMotion.webp
ffmpeg -i sprite.png -vf scale=1308:460 -pix_fmt rgba small.png && cwebp -q 86 -alpha_q 95 -m 6 small.png -o landing/ribbon-motion.webp
```
