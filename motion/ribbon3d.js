// Ruban de Murmure en 3D (Three.js) : une bande refermée et tordue d'un tour, faite de fines lignes,
// violette à gauche et turquoise à droite. Tout dépend du temps par des fonctions de période PERIOD :
// la boucle se referme sans raccord. VOICE (0 à 1) accélère l'onde et gonfle la bande.
import * as THREE from "https://cdn.jsdelivr.net/npm/three@0.181.2/+esm";

export const PERIOD = 1.5;

export function createRibbon(canvas, { width, height, camZ = 9, detail = true, VOICE = 0 }) {
        const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, premultipliedAlpha: false });
        renderer.setSize(width, height, false);
        renderer.setPixelRatio(1);
        renderer.setClearColor(0x000000, 0);

        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(26, width / height, 0.1, 100);
        camera.position.set(0, 0, camZ);

        // Maillage : U le long de la boucle, V en travers de la bande.
        const U = detail ? 720 : 240, V = detail ? 48 : 26;
        const geo = new THREE.BufferGeometry();
        const pos = new Float32Array((U + 1) * (V + 1) * 3);
        const uv = new Float32Array((U + 1) * (V + 1) * 2);
        const idx = [];
        for (let i = 0; i <= U; i++) for (let j = 0; j <= V; j++) {
          const k = i * (V + 1) + j;
          uv[k * 2] = i / U; uv[k * 2 + 1] = j / V;
          if (i < U && j < V) {
            const a = k, b = k + V + 1;
            idx.push(a, b, a + 1, b, b + 1, a + 1);
          }
        }
        geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
        geo.setAttribute("uv", new THREE.BufferAttribute(uv, 2));
        geo.setIndex(idx);

        const material = new THREE.ShaderMaterial({
          side: THREE.DoubleSide,
          transparent: false,
          uniforms: { uLight: { value: new THREE.Vector3(-0.75, 0.6, 0.35).normalize() } },
          vertexShader: /* glsl */ `
            varying vec2 vUv; varying vec3 vN; varying vec3 vView;
            void main() {
              vUv = uv;
              vec4 mv = modelViewMatrix * vec4(position, 1.0);
              vN = normalize(normalMatrix * normal);
              vView = normalize(-mv.xyz);
              gl_Position = projectionMatrix * mv;
            }`,
          fragmentShader: /* glsl */ `
            varying vec2 vUv; varying vec3 vN; varying vec3 vView;
            uniform vec3 uLight;
            const float PI = 3.14159265;
            void main() {
              vec3 n = normalize(vN);
              if (!gl_FrontFacing) n = -n;
              float u = vUv.x * 2.0 * PI;
              // Violet à gauche de la boucle, turquoise à droite.
              float side = smoothstep(-0.75, 0.85, cos(u - 0.25));
              vec3 deep = mix(vec3(0.20, 0.21, 0.55), vec3(0.13, 0.42, 0.50), side);
              vec3 mid  = mix(vec3(0.42, 0.43, 0.80), vec3(0.30, 0.66, 0.74), side);
              vec3 pale = mix(vec3(0.84, 0.84, 0.99), vec3(0.72, 0.89, 0.96), side);
              float diff = max(dot(n, uLight), 0.0);
              float rim = pow(1.0 - abs(dot(n, vView)), 2.0);
              float spec = pow(max(dot(reflect(-uLight, n), vView), 0.0), 10.0);
              // Dégradé en travers de la bande, comme sur le logo : un bord plus sombre, l'autre plus clair.
              float across = smoothstep(0.0, 1.0, vUv.y);
              vec3 col = mix(deep, mid, smoothstep(-0.1, 0.75, diff * 0.8 + across * 0.35));
              col = mix(col, pale, clamp(spec * 0.75 + rim * 0.3, 0.0, 0.85));
              // Fines lignes le long de la bande.
              float line = abs(fract(vUv.y * 26.0) - 0.5);
              col = mix(col, vec3(1.0), (1.0 - smoothstep(0.08, 0.2, line)) * 0.24);
              // Bords légèrement plus clairs.
              float edge = smoothstep(0.42, 0.5, abs(vUv.y - 0.5));
              col = mix(col, pale, edge * 0.35);
              gl_FragColor = vec4(col, 1.0);
            }`,
        });
        const mesh = new THREE.Mesh(geo, material);
        scene.add(mesh);

        // Ligne médiane : boucle arrondie, un peu triangulaire, avec un léger relief.
        function center(u, t) {
          const w = 2 * Math.PI * t / PERIOD;
          const r = 1 + 0.06 * Math.cos(3 * u + 0.4) + (0.012 + 0.02 * VOICE) * Math.sin(5 * u - w * (2 + 2 * VOICE));
          // Pliage : à mi-boucle, l'anneau se resserre un peu (la bascule vers l'avant fait le reste).
          const fold = (1 - Math.cos(w)) / 2;
          return new THREE.Vector3(1.32 * (1 - 0.12 * fold) * r * Math.cos(u), -0.7 * (1 - 0.18 * fold) * r * Math.sin(u),
                                   0.32 * Math.sin(2 * u + 0.6));
        }

        const P = new THREE.Vector3(), T = new THREE.Vector3(), N = new THREE.Vector3(), B = new THREE.Vector3(), D = new THREE.Vector3();
        function build(t) {
          const w = 2 * Math.PI * t / PERIOD;
          const swing = 0.32 * Math.sin(w);                  // la torsion oscille : les pincements glissent puis reviennent
          const fold = (1 - Math.cos(w)) / 2;               // 0 au début, 1 à mi-boucle, puis retour
          const breath = (1 + 0.28 * fold) * (1 + 0.06 * VOICE * Math.sin(w * 2));
          for (let i = 0; i <= U; i++) {
            const u = (i / U) * 2 * Math.PI;
            const c = center(u, t);
            const c2 = center(u + 1e-3, t);
            T.subVectors(c2, c).normalize();
            N.set(c.x, c.y, 0).normalize();                  // vers l'extérieur
            B.crossVectors(T, N).normalize();
            N.crossVectors(B, T).normalize();
            // Un tour complet sur la boucle : la bande se montre de profil en haut et en bas.
            const theta = u + swing;
            const width = 0.8 * (1 + 0.2 * Math.cos(u)) * (1 - 0.35 * Math.exp(-(((u - Math.PI - 0.3) / 0.45) ** 2))) * breath;
            D.copy(N).multiplyScalar(Math.cos(theta)).addScaledVector(B, Math.sin(theta));
            for (let j = 0; j <= V; j++) {
              const s = (j / V - 0.5) * width;
              P.copy(c).addScaledVector(D, s);
              const k = (i * (V + 1) + j) * 3;
              pos[k] = P.x; pos[k + 1] = P.y; pos[k + 2] = P.z;
            }
          }
          geo.attributes.position.needsUpdate = true;
          geo.computeVertexNormals();
          mesh.rotation.y = 0.16 * Math.sin(w);
          mesh.rotation.x = 0.1 * Math.cos(w) + 0.95 * fold;     // l'anneau bascule vers l'avant : le vide se referme
          mesh.rotation.z = 0.03 * Math.sin(w * 2);
        }



  return function renderAt(time) {
    build(((time % PERIOD) + PERIOD) % PERIOD);
    renderer.render(scene, camera);
  };
}
