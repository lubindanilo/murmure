const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const touch = matchMedia("(hover: none) and (pointer: coarse)").matches;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const $ = (id) => document.getElementById(id);

async function copyText(text, fallbackNode) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    if (!fallbackNode) return false;
    const r = document.createRange();
    r.selectNodeContents(fallbackNode);
    getSelection().removeAllRanges();
    getSelection().addRange(r);
    return document.execCommand("copy");
  }
}

// Installation : sur Mac, le bouton télécharge directement le DMG (c'est un lien).
// Sur téléphone, il ouvre une fenêtre pour s'envoyer le lien de la page.
const sheet = $("install");
document.querySelectorAll("[data-install]").forEach((btn) =>
  btn.addEventListener("click", (e) => {
    if (touch) { e.preventDefault(); sheet.showModal(); return; }
    showGuide();
  }),
);

// Guide d'installation : trois gestes, chacun s'anime à son tour.
const guide = $("guide");
const steps = guide.querySelectorAll(".step");
let stepTimer = 0;
function showStep(i) {
  steps.forEach((s, k) => s.classList.toggle("on", k === i));
}
function showGuide() {
  guide.hidden = false;
  guide.classList.remove("in");
  requestAnimationFrame(() => guide.classList.add("in"));
  clearInterval(stepTimer);
  if (reduce) { steps.forEach((s) => s.classList.add("on")); return; }
  let i = 0;
  showStep(i);
  stepTimer = setInterval(() => showStep(i = (i + 1) % steps.length), 2800);
}
guide.querySelector("[data-guide-close]").addEventListener("click", () => {
  clearInterval(stepTimer);
  guide.hidden = true;
});
addEventListener("keydown", (e) => { if (e.key === "Escape" && !guide.hidden) guide.querySelector("[data-guide-close]").click(); });
sheet.querySelector("[data-close]").addEventListener("click", () => sheet.close());
sheet.addEventListener("click", (e) => { if (e.target === sheet) sheet.close(); });

$("share").addEventListener("click", async () => {
  const url = location.origin + "/";
  if (navigator.share) {
    try { await navigator.share({ title: "Murmure, la dictée locale pour Mac", url }); return; } catch { /* annulé */ }
  }
  if (await copyText(url)) $("share-status").hidden = false;
});

// Apparitions au défilement (une seule fois)
const io = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
}, { threshold: 0.25 });
document.querySelectorAll(".reveal, .compare").forEach((el) => io.observe(el));

// Phrase qui s'allume mot à mot
const tagline = $("tagline");
if (tagline) {
  tagline.innerHTML = tagline.textContent.trim().split(/\s+/).map((w) => `<span class="w">${w}</span>`).join(" ");
  const words = tagline.querySelectorAll(".w");
  if (reduce) words.forEach((w) => w.classList.add("on"));
  else {
    const wo = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add("on"); wo.unobserve(e.target); }
    }, { rootMargin: "0px 0px -40% 0px" });
    words.forEach((w) => wo.observe(w));
  }
}

// Modes : la même dictée, quatre résultats
const outputs = {
  mail: ["Dans Mail", "« euh Claire la démo est prête on peut la faire jeudi à 14 h si ça te va »", "Claire, la démo est prête. On peut la faire jeudi à 14 h, si ça te va."],
  message: ["Dans Slack ou Messages", "« euh Claire la démo est prête on peut la faire jeudi à 14 h si ça te va »", "Claire, la démo est prête, on peut la faire jeudi à 14 h si ça te va"],
  prompt: ["Dans ChatGPT, Claude ou Cursor", "« résume le mail du client et euh propose trois réponses courtes et ajoute un objet »", "Résume le mail du client, puis :\n- propose trois réponses courtes ;\n- ajoute un objet."],
  english: ["Avec « Écrire en anglais »", "« euh Claire la démo est prête on peut la faire jeudi à 14 h si ça te va »", "Claire, the demo is ready. We can do it Thursday at 2 pm if that works for you."],
};
const modeIn = $("mode-in");
const tabs = [...document.querySelectorAll(".tabs button")];
const modeOut = $("mode-out");
const modeLabel = $("mode-label");
let modeIndex = 0, modeTimer, userPicked = false;

function showMode(i) {
  modeIndex = i;
  tabs.forEach((t, k) => t.setAttribute("aria-selected", String(k === i)));
  const [label, said, text] = outputs[tabs[i].dataset.mode];
  modeOut.classList.add("swap");
  requestAnimationFrame(() => {
    modeLabel.textContent = label;
    modeIn.textContent = said;
    modeOut.textContent = text;
    requestAnimationFrame(() => modeOut.classList.remove("swap"));
  });
}
tabs.forEach((t, i) => t.addEventListener("click", () => { userPicked = true; clearInterval(modeTimer); showMode(i); }));
tabs.forEach((t, i) => t.addEventListener("keydown", (e) => {
  if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
  const next = (i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length;
  tabs[next].focus(); tabs[next].click();
}));
showMode(0);
if (!reduce) new IntersectionObserver(([e]) => {
  clearInterval(modeTimer);
  if (e.isIntersecting && !userPicked) modeTimer = setInterval(() => showMode((modeIndex + 1) % tabs.length), 3500);
}).observe(document.querySelector(".modes"));

// Démonstration : touche maintenue, la voix s'affiche dans l'encoche, le texte se colle dans Notes
const typed = $("typed");
const hud = $("hud");
const states = [...hud.querySelectorAll(".notch-state")];
const voice = $("voice");
const mbRibbon = $("mb-ribbon");
const menubarInk = "#1e2433";
// Le ruban en mouvement : les 45 images d'une boucle de 1,5 s, rendues en 3D avec HyperFrames
// (motion/ruban-frames) et rangées en grille 9 × 5. Il se plie, plus vite quand la voix monte.
const ribbonSheet = new Image();
ribbonSheet.src = "/ribbon-motion.webp";
const RIBBON = { frames: 45, cols: 9, loop: 1.5 };
function drawRibbon(canvas, phase = 0, ink = null) {
  if (!ribbonSheet.naturalWidth) return;
  const rows = Math.ceil(RIBBON.frames / RIBBON.cols);
  const fw = ribbonSheet.naturalWidth / RIBBON.cols, fh = ribbonSheet.naturalHeight / rows;
  const i = Math.floor((phase - Math.floor(phase)) * RIBBON.frames) % RIBBON.frames;
  const ctx = canvas.getContext("2d");
  ctx.globalCompositeOperation = "source-over";
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(ribbonSheet, (i % RIBBON.cols) * fw, Math.floor(i / RIBBON.cols) * fh, fw, fh, 0, 0, canvas.width, canvas.height);
  if (ink) {
    // Silhouette d'une seule couleur, comme une icône de barre des menus.
    ctx.globalCompositeOperation = "source-in";
    ctx.fillStyle = ink;
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.globalCompositeOperation = "source-over";
  }
}
// Immobiles au repos.
function restRibbons() {
  drawRibbon(mbRibbon, 0, menubarInk);
  drawRibbon(voice);
}
ribbonSheet.decode().then(restRibbons).catch(() => {});
const scenes = [
  { app: "Notes", title: "Notes", h: "Au fil des idées", prev: "Reprendre le fil du projet.", text: "Je t'envoie le brouillon demain matin." },
  { app: "Mail", title: "Nouveau message", h: "Réunion de demain", prev: "Salut Axel,", text: "la réunion est décalée à 15 h. Tu peux prévenir Louis ?" },
  { app: "Slack", title: "# produit", h: "Lancement", prev: "Bonne nouvelle :", text: "la version 2 part en recette ce soir. Merci à tous pour le sprint" },
];
let visible = true;

function setState(name) {
  states.forEach((el) => el.classList.toggle("on", el.dataset.state === name));
  hud.classList.toggle("open", name !== "idle");
}

async function demo() {
  if (reduce) { typed.textContent = scenes[0].text; return; }
  let i = 0;
  for (;;) {
    while (!visible) await sleep(300);
    const s = scenes[i % scenes.length];
    $("mb-app").textContent = s.app;
    $("win-title").textContent = s.title;
    $("win-h").textContent = s.h;
    $("prev").textContent = s.prev;
    typed.textContent = "";
    setState("idle");
    await sleep(1000);
    await sleep(350);
    setState("listen");
    const start = performance.now();
    let phase = 0, last = start;
    while (performance.now() - start < 2600) {
      const now = performance.now(), t = now / 1000;
      const level = 0.3 + 0.7 * Math.abs(Math.sin(t * 3.1) * Math.sin(t * 1.7));
      phase += ((now - last) / 1000) * (0.75 + 1.25 * level) / RIBBON.loop;
      last = now;
      drawRibbon(voice, phase);
      drawRibbon(mbRibbon, phase, menubarInk);
      await sleep(33);
    }
    restRibbons();
    setState("clean");
    await sleep(800);
    setState("done");
    typed.textContent = s.text;
    typed.classList.add("fresh");
    requestAnimationFrame(() => requestAnimationFrame(() => typed.classList.remove("fresh")));
    await sleep(1200);
    setState("idle");
    await sleep(2600);
    i++;
  }
}
let started = false;
new IntersectionObserver(([e]) => {
  visible = e.isIntersecting;
  if (visible && !started) { started = true; demo(); }
}).observe(document.querySelector(".screen"));
