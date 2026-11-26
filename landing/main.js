const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Copier la commande d'installation (deux blocs identiques sur la page)
document.querySelectorAll("[data-copy]").forEach((btn) => {
  let timer;
  btn.addEventListener("click", async () => {
    const code = btn.parentElement.querySelector("code");
    const text = code.textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const r = document.createRange();
      r.selectNodeContents(code);
      getSelection().removeAllRanges();
      getSelection().addRange(r);
      document.execCommand("copy");
    }
    btn.classList.add("done");
    btn.querySelector(".copy-label").textContent = "Copié";
    clearTimeout(timer);
    timer = setTimeout(() => {
      btn.classList.remove("done");
      btn.querySelector(".copy-label").textContent = "Copier";
    }, 2000);
  });
});

// Apparitions au défilement (une seule fois)
const io = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
}, { threshold: 0.2 });
document.querySelectorAll(".reveal").forEach((el) => io.observe(el));

// Phrase qui s'allume mot à mot
const tagline = document.getElementById("tagline");
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

// Modes : le mode actif change toutes les deux secondes quand la carte est visible
const modes = [...document.querySelectorAll(".modes li")];
if (modes.length) {
  let m = 0, modeTimer;
  modes[0].classList.add("on");
  const mo = new IntersectionObserver(([e]) => {
    clearInterval(modeTimer);
    if (e.isIntersecting && !reduce) modeTimer = setInterval(() => {
      modes[m].classList.remove("on");
      m = (m + 1) % modes.length;
      modes[m].classList.add("on");
    }, 2000);
  });
  mo.observe(document.getElementById("card-modes"));
}

// Démonstration : on maintient la touche, on parle, Murmure colle un texte propre
const typed = document.getElementById("typed");
const hud = document.getElementById("hud");
const label = document.getElementById("hud-label");
const key = document.getElementById("key");
const hint = document.getElementById("stage-hint");
const title = document.getElementById("win-title");
const meta = document.getElementById("win-meta");
const bars = hud ? [...hud.querySelectorAll(".bars i")] : [];
const scenes = [
  { title: "Nouveau message", meta: "À : Axel Moreau", text: "Salut Axel, la réunion de demain est décalée à 15 h. Tu peux prévenir Louis ?" },
  { title: "Notes", meta: "Jeudi, 9:42", text: "Idées pour le lancement : une vidéo de 30 secondes, un mail aux 40 premiers clients et une offre de bienvenue." },
  { title: "Assistant IA", meta: "Nouvelle conversation", text: "Résume les trois derniers mails du client et propose une réponse courte, sur un ton chaleureux." },
];
const profile = [0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35];
let visible = true;

async function demo() {
  if (!typed) return;
  if (reduce) { typed.textContent = scenes[0].text; return; }
  let i = 0;
  for (;;) {
    while (!visible) await sleep(300);
    const scene = scenes[i % scenes.length];
    await sleep(900);
    title.textContent = scene.title;
    meta.textContent = scene.meta;
    typed.textContent = "";
    // Touche enfoncée : le panneau apparaît et suit la voix
    key.classList.add("down");
    hint.textContent = "Vous parlez…";
    hud.classList.remove("hidden", "thinking");
    const start = performance.now();
    while (performance.now() - start < 2800) {
      const t = performance.now() / 1000;
      const level = 0.35 + 0.65 * Math.abs(Math.sin(t * 3.1) * Math.sin(t * 1.7));
      bars.forEach((b, k) => { b.style.scale = `1 ${Math.max(0.18, level * profile[k] * (0.75 + 0.25 * Math.sin(t * 13 + k)))}`; });
      label.textContent = `0:0${Math.floor((performance.now() - start) / 1000) + 1}`;
      await sleep(70);
    }
    // Relâchée : transcription et nettoyage, puis collage
    key.classList.remove("down");
    hint.textContent = "Relâchez, c'est écrit";
    hud.classList.add("thinking");
    label.textContent = "Transcription";
    bars.forEach((b) => { b.style.scale = "1 0.27"; });
    await sleep(650);
    hud.classList.add("hidden");
    typed.textContent = scene.text;
    typed.classList.add("fresh");
    requestAnimationFrame(() => requestAnimationFrame(() => typed.classList.remove("fresh")));
    await sleep(3200);
    hint.textContent = "Maintenez la touche et parlez";
    i++;
  }
}
const stage = document.querySelector(".stage");
if (stage) {
  let started = false;
  new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    if (visible && !started) { started = true; demo(); }
  }).observe(stage);
}
