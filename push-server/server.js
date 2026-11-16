require('dotenv').config();
const express = require('express');
const webpush = require('web-push');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = parseInt(process.env.PORT || '3000', 10);
const SUBSCRIPTIONS_FILE = path.join(__dirname, 'subscriptions.json');

const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:admin@scinsta.local';
const VAPID_PUBLIC_KEY = process.env.VAPID_PUBLIC_KEY || '';
const VAPID_PRIVATE_KEY = process.env.VAPID_PRIVATE_KEY || '';
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || '';

if (VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
} else {
  console.warn('[push-server] ADVERTENCIA: VAPID_PUBLIC_KEY o VAPID_PRIVATE_KEY no configuradas en .env');
}

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

function readSubscriptions() {
  try {
    if (!fs.existsSync(SUBSCRIPTIONS_FILE)) {
      return [];
    }
    const raw = fs.readFileSync(SUBSCRIPTIONS_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch (err) {
    console.error('[push-server] Error leyendo subscriptions.json:', err.message);
    return [];
  }
}

function writeSubscriptions(subscriptions) {
  try {
    fs.writeFileSync(SUBSCRIPTIONS_FILE, JSON.stringify(subscriptions, null, 2), 'utf8');
  } catch (err) {
    console.error('[push-server] Error guardando subscriptions.json:', err.message);
  }
}

// GET /api/vapid-public-key
app.get('/api/vapid-public-key', (req, res) => {
  res.json({ publicKey: process.env.VAPID_PUBLIC_KEY });
});

// POST /api/subscribe
app.post('/api/subscribe', (req, res) => {
  const subscription = req.body;
  if (!subscription || typeof subscription.endpoint !== 'string' || !subscription.endpoint.trim()) {
    return res.status(400).json({ error: 'Objeto PushSubscription inválido: requiere endpoint' });
  }

  const subscriptions = readSubscriptions();
  const existingIndex = subscriptions.findIndex((sub) => sub.endpoint === subscription.endpoint);

  if (existingIndex !== -1) {
    subscriptions[existingIndex] = subscription;
  } else {
    subscriptions.push(subscription);
  }

  writeSubscriptions(subscriptions);
  return res.status(201).json({ status: 'subscribed', count: subscriptions.length });
});

// POST /api/notify (Cumplimiento estricto de Contrato A y Contrato B)
app.post('/api/notify', async (req, res) => {
  const authHeader = req.headers.authorization;
  if (!WEBHOOK_SECRET || !authHeader || authHeader !== `Bearer ${WEBHOOK_SECRET}`) {
    return res.status(401).json({ error: 'No autorizado' });
  }

  const { messageId, senderName, text, threadId, timestamp } = req.body || {};

  // Regla exacta de construcción de targetUrl (Contrato A & B)
  const targetUrl =
    typeof threadId === 'string' && threadId.trim() !== ''
      ? `scinsta://direct-thread?id=${threadId.trim()}`
      : 'scinsta://direct-inbox';

  const payload = JSON.stringify({
    title: senderName || 'SCInsta',
    body: text,
    tag: threadId || 'system',
    data: {
      targetUrl,
      messageId,
      timestamp
    }
  });

  const subscriptions = readSubscriptions();
  if (subscriptions.length === 0) {
    return res.status(200).json({ sent: 0, removed: 0, targetUrl });
  }

  const expiredEndpoints = new Set();
  let sentCount = 0;

  await Promise.all(
    subscriptions.map(async (sub) => {
      try {
        await webpush.sendNotification(sub, payload);
        sentCount += 1;
      } catch (err) {
        if (err.statusCode === 404 || err.statusCode === 410) {
          expiredEndpoints.add(sub.endpoint);
        } else {
          console.error('[push-server] Error enviando notificación Web Push:', err.statusCode || err.message);
        }
      }
    })
  );

  if (expiredEndpoints.size > 0) {
    const activeSubscriptions = subscriptions.filter((sub) => !expiredEndpoints.has(sub.endpoint));
    writeSubscriptions(activeSubscriptions);
  }

  return res.status(200).json({
    sent: sentCount,
    removed: expiredEndpoints.size,
    targetUrl
  });
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`[push-server] Escuchando en http://127.0.0.1:${PORT}`);
});
