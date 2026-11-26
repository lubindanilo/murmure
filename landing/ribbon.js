// Ruban de Murmure dessiné en code (même modèle que Sources/Murmure/UI/Ribbon.swift) :
// une bande refermée, tordue d'un demi-tour en haut et en bas, violet à gauche, turquoise à droite.
// t = temps en secondes, level = niveau de la voix (0 à 1).
(() => {
  const radius = (th, t, level) =>
    1 + 0.05 * Math.cos(3 * th) + 0.02 * Math.sin(2 * th + t * 0.8) + level * 0.045 * Math.sin(4 * th - t * 7);

  function grid(t, level, lines, steps, band) {
    const rows = [];
    for (let i = 0; i <= steps; i++) {
      const th = (i / steps) * Math.PI * 2;
      const r = radius(th, t, level);
      const cx = Math.cos(th) * r, cy = Math.sin(th) * 0.86 * r;
      const th2 = th + 0.001, r2 = radius(th2, t, level);
      const dx = Math.cos(th2) * r2 - cx, dy = Math.sin(th2) * 0.86 * r2 - cy;
      const len = Math.max(Math.hypot(dx, dy), 1e-9);
      const nx = -dy / len, ny = dx / len;
      const psi = th + 0.22 * Math.sin(t * 0.5);
      const neck = 1 - 0.45 * Math.exp(-(((th - Math.PI - 0.35) / 0.4) ** 2));
      const w = 0.36 * band * (1 + 0.2 * Math.cos(th)) * neck * (1 + 0.14 * level) * Math.cos(psi);
      const row = [];
      for (let j = 0; j <= lines; j++) {
        const k = -1 + (2 * j) / lines;
        row.push([cx + nx * w * k, cy + ny * w * k, psi]);
      }
      rows.push(row);
    }
    return rows;
  }

  // Cadre du ruban au repos, qui sert à le placer.
  const rest = (() => {
    const pts = grid(0, 0, 2, 360, 1).flat();
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const x = Math.min(...xs), y = Math.min(...ys);
    return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
  })();

  const violet = [58, 62, 150], violetLight = [205, 205, 250];
  const teal = [40, 118, 138], tealLight = [178, 222, 242];
  const mix = (a, b, f) => a.map((v, i) => v + (b[i] - v) * f);

  function color(th, psi, j, lines) {
    const side = (Math.cos(th) + 1) / 2, f = side * side * (3 - 2 * side);
    const dark = mix(violet, teal, f), light = mix(violetLight, tealLight, f);
    const k = ((j + 0.5) / lines) * 2 - 1;
    const facing = Math.abs(Math.cos(psi)), turn = Math.cos(psi) >= 0 ? 1 : -1;
    const sheen = 0.5 + 0.45 * Math.sin(psi) * turn;
    const lum = Math.min(1, Math.max(0, 0.05 + 0.8 * sheen * (0.55 + 0.45 * facing) + 0.22 * k * turn));
    const stripe = j % 2 === 0 ? 1.06 : 0.97;
    return `rgb(${mix(dark, light, lum).map((v) => Math.min(255, Math.round(v * stripe))).join(",")})`;
  }

  // Dessine dans un canvas (taille en pixels du canvas). mono = couleur unie pour une silhouette.
  window.drawRibbon = (canvas, { t = 0, level = 0, mono = null } = {}) => {
    const ctx = canvas.getContext("2d");
    const W = canvas.width, H = canvas.height;
    const small = H < 80;
    const lines = small ? 12 : 30, steps = small ? 84 : 200;
    const band = mono ? 0.72 : 1;
    const g = grid(t, level, lines, steps, band);
    const s = Math.min(W / rest.w, H / rest.h) * 0.9;
    const ox = W / 2 - (rest.x + rest.w / 2) * s, oy = H / 2 - (rest.y + rest.h / 2) * s;
    const tilt = 0.05 * Math.sin(t * 0.3), ct = Math.cos(tilt), st = Math.sin(tilt);
    const X = (p) => ox + (p[0] * ct - p[1] * st) * s;
    const Y = (p) => oy + (p[0] * st + p[1] * ct) * s;
    ctx.clearRect(0, 0, W, H);
    ctx.lineWidth = small ? 0.6 : 1;
    for (let i = 0; i < steps; i++) {
      const th = ((i + 0.5) / steps) * Math.PI * 2;
      for (let j = 0; j < lines; j++) {
        const a = g[i][j], b = g[i + 1][j], c = g[i + 1][j + 1], d = g[i][j + 1];
        ctx.beginPath();
        ctx.moveTo(X(a), Y(a)); ctx.lineTo(X(b), Y(b)); ctx.lineTo(X(c), Y(c)); ctx.lineTo(X(d), Y(d));
        ctx.closePath();
        ctx.fillStyle = ctx.strokeStyle = mono || color(th, a[2], j, lines);
        ctx.fill(); ctx.stroke();
      }
    }
  };
})();
