// Serveur de licences Murmure : essai de 7 jours par Mac, achats Paddle, jetons signés Ed25519.
// Node 24, aucune dépendance (http, crypto et sqlite intégrés).
import { createServer } from 'node:http';
import { createHmac, createPrivateKey, sign, timingSafeEqual } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const env = (name, fallback) => {
  const v = process.env[name];
  if (v === undefined || v === '') {
    if (fallback === undefined) throw new Error(`Variable d'environnement manquante : ${name}`);
    return fallback;
  }
  return v;
};

const config = {
  port: Number(env('PORT', '8787')),
  publicURL: env('PUBLIC_URL', 'http://localhost:8787').replace(/\/$/, ''),
  dbPath: env('DB_PATH', join(here, '..', 'data', 'murmure.db')),
  trialDays: Number(env('TRIAL_DAYS', '7')),
  maxDevices: Number(env('MAX_DEVICES', '3')),
  paddleEnv: env('PADDLE_ENV', 'sandbox'),
  paddleClientToken: env('PADDLE_CLIENT_TOKEN', ''),
  paddlePriceID: env('PADDLE_PRICE_ID', ''),
  paddleWebhookSecret: env('PADDLE_WEBHOOK_SECRET', ''),
  paddleAPIKey: env('PADDLE_API_KEY', ''),
};
const privateKey = createPrivateKey({
  key: Buffer.from(env('LICENSE_PRIVATE_KEY'), 'base64'),
  format: 'der',
  type: 'pkcs8',
});
const paddleAPI = config.paddleEnv === 'production' ? 'https://api.paddle.com' : 'https://sandbox-api.paddle.com';

// ---------- Base de données ----------

mkdirSync(dirname(config.dbPath), { recursive: true });
const db = new DatabaseSync(config.dbPath);
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL,
    app_version TEXT,
    license_id TEXT
  );
  CREATE TABLE IF NOT EXISTS licenses (
    id TEXT PRIMARY KEY,              -- id d'abonnement Paddle, ou id de transaction pour un achat unique
    kind TEXT NOT NULL,               -- subscription | lifetime
    status TEXT NOT NULL,             -- active, trialing, past_due, paused, canceled, refunded
    email TEXT,
    customer_id TEXT,
    period_end TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS transactions (
    id TEXT PRIMARY KEY,
    license_id TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS webhook_events (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    received_at TEXT NOT NULL
  );
`);

const q = {
  device: db.prepare('SELECT * FROM devices WHERE id = ?'),
  insertDevice: db.prepare('INSERT INTO devices (id, first_seen, last_seen, app_version) VALUES (?, ?, ?, ?)'),
  touchDevice: db.prepare('UPDATE devices SET last_seen = ?, app_version = ?, first_seen = ? WHERE id = ?'),
  linkDevice: db.prepare('UPDATE devices SET license_id = ? WHERE id = ?'),
  devicesForLicense: db.prepare('SELECT COUNT(*) AS n FROM devices WHERE license_id = ?'),
  license: db.prepare('SELECT * FROM licenses WHERE id = ?'),
  upsertLicense: db.prepare(`
    INSERT INTO licenses (id, kind, status, email, customer_id, period_end, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET status = excluded.status,
      email = COALESCE(excluded.email, licenses.email),
      customer_id = COALESCE(excluded.customer_id, licenses.customer_id),
      period_end = COALESCE(excluded.period_end, licenses.period_end),
      updated_at = excluded.updated_at`),
  setStatus: db.prepare('UPDATE licenses SET status = ?, period_end = COALESCE(?, period_end), updated_at = ? WHERE id = ?'),
  transaction: db.prepare('SELECT * FROM transactions WHERE id = ?'),
  insertTransaction: db.prepare('INSERT OR IGNORE INTO transactions (id, license_id, created_at) VALUES (?, ?, ?)'),
  event: db.prepare('SELECT id FROM webhook_events WHERE id = ?'),
  insertEvent: db.prepare('INSERT INTO webhook_events (id, type, received_at) VALUES (?, ?, ?)'),
};

// ---------- Jetons ----------

// Dates sans millisecondes : le décodeur ISO 8601 de Swift les refuse.
const iso = (d) => new Date(d).toISOString().replace(/\.\d{3}Z$/, 'Z');
const b64url = (buf) => Buffer.from(buf).toString('base64url');

function isLicenseActive(license) {
  if (!license) return false;
  if (license.kind === 'lifetime') return license.status === 'active';
  return ['active', 'trialing', 'past_due'].includes(license.status);
}

function tokenFor(device) {
  const license = device.license_id ? q.license.get(device.license_id) : null;
  const trialEnds = new Date(new Date(device.first_seen).getTime() + config.trialDays * 86_400_000);
  const pro = isLicenseActive(license);
  const payload = {
    device: device.id,
    plan: pro ? 'pro' : 'trial',
    trial_ends_at: iso(trialEnds),
    expires_at: pro && license.kind === 'subscription' && license.period_end ? iso(license.period_end) : null,
    issued_at: iso(Date.now()),
    email: pro ? license.email ?? null : null,
  };
  const encoded = b64url(JSON.stringify(payload));
  const signature = b64url(sign(null, Buffer.from(encoded), privateKey));
  return { token: encoded, signature, plan: payload.plan };
}

// ---------- Paddle ----------

function verifyPaddleSignature(raw, header) {
  if (!config.paddleWebhookSecret || !header) return false;
  const parts = Object.fromEntries(header.split(';').map((p) => p.split('=')));
  const ts = Number(parts.ts);
  if (!ts || !parts.h1 || Math.abs(Date.now() / 1000 - ts) > 300) return false;
  const expected = createHmac('sha256', config.paddleWebhookSecret).update(`${ts}:${raw}`).digest('hex');
  const a = Buffer.from(expected, 'hex');
  const b = Buffer.from(parts.h1, 'hex');
  return a.length === b.length && timingSafeEqual(a, b);
}

async function paddle(path, init = {}) {
  if (!config.paddleAPIKey) return null;
  const res = await fetch(paddleAPI + path, {
    ...init,
    headers: { Authorization: `Bearer ${config.paddleAPIKey}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
  if (!res.ok) {
    console.error('Paddle', path, res.status, await res.text());
    return null;
  }
  return (await res.json()).data;
}

async function customerEmail(customerID) {
  if (!customerID) return null;
  try {
    return (await paddle(`/customers/${customerID}`))?.email ?? null;
  } catch {
    return null;
  }
}

async function handleWebhook(event) {
  const now = iso(Date.now());
  const data = event.data ?? {};
  switch (event.event_type) {
    case 'transaction.completed': {
      const licenseID = data.subscription_id ?? data.id;
      const kind = data.subscription_id ? 'subscription' : 'lifetime';
      const email = await customerEmail(data.customer_id);
      const periodEnd = data.billing_period?.ends_at ?? null;
      q.upsertLicense.run(licenseID, kind, 'active', email, data.customer_id ?? null, periodEnd, now, now);
      q.insertTransaction.run(data.id, licenseID, now);
      const deviceID = data.custom_data?.device_id;
      if (deviceID && q.device.get(deviceID)) q.linkDevice.run(licenseID, deviceID);
      console.log(`Licence ${licenseID} (${kind}) activée${deviceID ? ` pour ${deviceID}` : ''}`);
      break;
    }
    case 'subscription.created':
    case 'subscription.activated':
    case 'subscription.updated':
    case 'subscription.trialing':
    case 'subscription.past_due':
    case 'subscription.paused':
    case 'subscription.resumed':
    case 'subscription.canceled': {
      const periodEnd = data.current_billing_period?.ends_at ?? null;
      if (q.license.get(data.id)) {
        q.setStatus.run(data.status, periodEnd, now, data.id);
      } else {
        const email = await customerEmail(data.customer_id);
        q.upsertLicense.run(data.id, 'subscription', data.status, email, data.customer_id ?? null, periodEnd, now, now);
      }
      break;
    }
    case 'adjustment.created':
    case 'adjustment.updated': {
      // Remboursement total accepté : la licence est retirée.
      if (data.action === 'refund' && data.status === 'approved' && data.type === 'full') {
        const tx = q.transaction.get(data.transaction_id);
        if (tx) q.setStatus.run('refunded', null, now, tx.license_id);
      }
      break;
    }
    default:
      break;
  }
}

// ---------- HTTP ----------

const buckets = new Map();
function rateLimited(ip, limit = 60) {
  const minute = Math.floor(Date.now() / 60_000);
  const key = `${ip}:${minute}`;
  const n = (buckets.get(key) ?? 0) + 1;
  buckets.set(key, n);
  if (buckets.size > 10_000) buckets.clear();
  return n > limit;
}

const send = (res, status, body, headers = {}) => {
  const isJSON = typeof body !== 'string';
  res.writeHead(status, {
    'Content-Type': isJSON ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(isJSON ? JSON.stringify(body) : body);
};

const readBody = (req) =>
  new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 1_000_000) reject(new Error('Corps trop volumineux'));
      else chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });

const validDevice = (id) => typeof id === 'string' && /^[0-9a-f]{32}$/.test(id);
const page = (name, vars) =>
  readFileSync(join(here, '..', 'pages', name), 'utf8').replace(/\{\{(\w+)\}\}/g, (_, k) => vars[k] ?? '');

const routes = {
  'GET /health': () => ({ status: 200, body: { ok: true } }),

  'POST /v1/device': async (req, body) => {
    const { device_id: id, app_version: version, trial_start: trialStart } = JSON.parse(body || '{}');
    if (!validDevice(id)) return { status: 400, body: { error: 'Identifiant de Mac invalide.' } };
    const now = iso(Date.now());
    let device = q.device.get(id);
    // L'essai démarre à la première ouverture connue, côté serveur ou côté Mac (la plus ancienne).
    const claimed = Date.parse(trialStart);
    const earliest = (a) => (Number.isFinite(claimed) && claimed < Date.parse(a) ? iso(claimed) : a);
    if (!device) {
      q.insertDevice.run(id, earliest(now), now, version ?? null);
    } else {
      q.touchDevice.run(now, version ?? null, earliest(device.first_seen), id);
    }
    device = q.device.get(id);
    return { status: 200, body: tokenFor(device) };
  },

  'POST /v1/restore': async (req, body) => {
    const { device_id: id, transaction_id: txID, email } = JSON.parse(body || '{}');
    if (!validDevice(id) || typeof txID !== 'string') return { status: 400, body: { error: 'Requête invalide.' } };
    const tx = q.transaction.get(txID.trim());
    const license = tx && q.license.get(tx.license_id);
    if (!license || !isLicenseActive(license)) {
      return { status: 404, body: { error: 'Aucun achat actif ne correspond à ce numéro de transaction.' } };
    }
    if (license.email && String(email ?? '').trim().toLowerCase() !== license.email.toLowerCase()) {
      return { status: 403, body: { error: "L'e-mail ne correspond pas à celui de l'achat." } };
    }
    let device = q.device.get(id);
    if (!device) {
      const now = iso(Date.now());
      q.insertDevice.run(id, now, now, null);
      device = q.device.get(id);
    }
    if (device.license_id !== license.id && q.devicesForLicense.get(license.id).n >= config.maxDevices) {
      return { status: 409, body: { error: `Cette licence est déjà active sur ${config.maxDevices} Mac.` } };
    }
    q.linkDevice.run(license.id, id);
    return { status: 200, body: tokenFor(q.device.get(id)) };
  },

  'POST /v1/paddle/webhook': async (req, body) => {
    if (!verifyPaddleSignature(body, req.headers['paddle-signature'])) {
      return { status: 401, body: { error: 'Signature invalide.' } };
    }
    const event = JSON.parse(body);
    if (q.event.get(event.event_id)) return { status: 200, body: { ok: true, duplicate: true } };
    await handleWebhook(event);
    q.insertEvent.run(event.event_id, event.event_type, iso(Date.now()));
    return { status: 200, body: { ok: true } };
  },

  'GET /buy': async (req, _body, url) => {
    const device = url.searchParams.get('device') ?? '';
    if (!config.paddleClientToken || !config.paddlePriceID) {
      return { status: 503, body: page('message.html', { title: 'Bientôt disponible', text: "Le paiement n'est pas encore ouvert." }) };
    }
    return {
      status: 200,
      body: page('buy.html', {
        device: validDevice(device) ? device : '',
        token: config.paddleClientToken,
        price: config.paddlePriceID,
        environment: config.paddleEnv,
        success: `${config.publicURL}/merci`,
      }),
    };
  },

  'GET /merci': () => ({
    status: 200,
    body: page('message.html', {
      title: 'Merci !',
      text: "Le paiement est reçu. Retournez dans Murmure : l'activation se fait toute seule en quelques secondes.",
    }),
  }),

  'GET /account': async (req, _body, url) => {
    const device = q.device.get(url.searchParams.get('device') ?? '');
    const license = device?.license_id && q.license.get(device.license_id);
    if (license?.customer_id && config.paddleAPIKey) {
      const subscriptionIDs = license.kind === 'subscription' ? [license.id] : [];
      const session = await paddle(`/customers/${license.customer_id}/portal-sessions`, {
        method: 'POST',
        body: JSON.stringify({ subscription_ids: subscriptionIDs }),
      });
      const target = session?.urls?.general?.overview;
      if (target) return { status: 302, body: '', headers: { Location: target } };
    }
    return {
      status: 200,
      body: page('message.html', {
        title: 'Votre compte',
        text: "Pour gérer votre abonnement, utilisez le lien présent dans le reçu Paddle reçu par e-mail.",
      }),
    };
  },
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url, config.publicURL);
  const handler = routes[`${req.method} ${url.pathname}`];
  const ip = req.headers['x-forwarded-for']?.split(',')[0].trim() ?? req.socket.remoteAddress;
  if (!handler) return send(res, 404, { error: 'Introuvable.' });
  if (!url.pathname.includes('webhook') && rateLimited(ip)) return send(res, 429, { error: 'Trop de requêtes.' });
  try {
    const body = req.method === 'POST' ? await readBody(req) : '';
    const result = await handler(req, body, url);
    send(res, result.status, result.body, result.headers);
  } catch (error) {
    console.error(req.method, url.pathname, error);
    send(res, error instanceof SyntaxError ? 400 : 500, { error: 'Erreur du serveur de licences.' });
  }
});

server.listen(config.port, () => {
  console.log(`Serveur de licences Murmure sur :${config.port} (Paddle ${config.paddleEnv})`);
});
