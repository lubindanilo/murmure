const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Copier la commande d'installation
const copy = document.getElementById("copy");
copy?.addEventListener("click", async () => {
  const text = document.getElementById("cmd").textContent.trim();
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const r = document.createRange();
    r.selectNodeContents(document.getElementById("cmd"));
    getSelection().removeAllRanges();
    getSelection().addRange(r);
    document.execCommand("copy");
  }
  copy.classList.add("done");
  copy.querySelector("span").textContent = "Copié";
  copy.querySelector("i").className = "ph ph-check";
  setTimeout(() => {
    copy.classList.remove("done");
    copy.querySelector("span").textContent = "Copier";
    copy.querySelector("i").className = "ph ph-copy";
  }, 2000);
});

// Apparitions au défilement (une seule fois)
const io = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
}, { threshold: 0.15 });
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
    }, { rootMargin: "0px 0px -35% 0px" });
    words.forEach((w) => wo.observe(w));
  }
}

// Démonstration : on dicte, Murmure transcrit et colle
const typed = document.getElementById("typed");
const hud = document.getElementById("hud");
const label = document.getElementById("hud-label");
const bars = hud ? [...hud.querySelectorAll(".bars i")] : [];
const phrases = [
  "Salut Axel, la réunion de demain est décalée à 15 h. Tu peux prévenir Louis ?",
  "Merci pour le devis. Je le relis ce soir et je te réponds demain matin.",
  "Peux-tu ajouter un résumé des mails urgents sur Slack chaque matin à 9 h ?",
];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = [0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35];

async function demo() {
  if (!typed) return;
  if (reduce) { typed.textContent = phrases[0]; hud.classList.add("hidden"); return; }
  let i = 0;
  for (;;) {
    typed.textContent = "";
    hud.classList.remove("hidden", "thinking");
    const start = performance.now();
    while (performance.now() - start < 2600) {
      const t = performance.now() / 1000;
      const level = 0.4 + 0.6 * Math.abs(Math.sin(t * 3.1) * Math.sin(t * 1.7));
      bars.forEach((b, k) => { b.style.height = `${4 + level * 18 * profile[k] * (0.75 + 0.25 * Math.sin(t * 13 + k))}px`; });
      label.textContent = `0:0${Math.floor((performance.now() - start) / 1000) + 1}`;
      await sleep(80);
    }
    hud.classList.add("thinking");
    label.textContent = "Transcription";
    bars.forEach((b) => { b.style.height = "6px"; });
    await sleep(700);
    hud.classList.add("hidden");
    typed.textContent = phrases[i % phrases.length];
    i++;
    await sleep(3600);
  }
}
const demoObserver = new IntersectionObserver((entries) => {
  if (entries.some((e) => e.isIntersecting)) { demoObserver.disconnect(); demo(); }
});
const demoEl = document.querySelector(".demo");
if (demoEl) demoObserver.observe(demoEl);
