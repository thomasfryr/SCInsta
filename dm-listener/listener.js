'use strict';

require('dotenv').config();
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const { chromium } = require('playwright');

// ============================================================================
// Configuración y Rutas (Contrato B & C)
// ============================================================================
const PUSH_WEBHOOK_URL = process.env.PUSH_WEBHOOK_URL || 'http://127.0.0.1:3000/api/notify';
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || '';
const COOKIES_PATH = path.resolve(process.env.COOKIES_PATH || './cookies.json');
const USERS_CACHE_PATH = path.resolve(process.env.USERS_CACHE_PATH || './users_cache.json');
const WHITELIST_PATH = path.resolve(process.env.WHITELIST_PATH || './whitelist.json');
const MUTED_THREADS_PATH = path.resolve(process.env.MUTED_THREADS_PATH || './muted_threads.json');

const INSTAGRAM_INBOX_URL = 'https://www.instagram.com/direct/inbox/';
const DESKTOP_USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const ABORTED_RESOURCE_TYPES = new Set(['image', 'media', 'font', 'stylesheet']);
const ABORTED_TELEMETRY_PATTERNS = ['/logging', 'falco', '/bz', 'graph.instagram.com/logging_client_events'];

// ============================================================================
// Estado en Memoria y Deduplicación Circular (Contrato C: máx 500 item_id)
// ============================================================================
const MAX_DEDUP_SIZE = 500;
const processedItemIds = new Set();

let usersCache = {};
let ownUserId = null;
let sessionExpiredHandled = false;
let stopReconnectionLoops = false;
let activeBrowser = null;

/**
 * Registra un item_id en el buffer circular de 500 elementos.
 * Retorna true si el mensaje YA fue procesado (duplicado).
 */
function isDuplicateMessage(itemId) {
  if (!itemId) return true;
  const key = String(itemId).trim();
  if (!key) return true;

  if (processedItemIds.has(key)) {
    return true;
  }

  if (processedItemIds.size >= MAX_DEDUP_SIZE) {
    const oldestKey = processedItemIds.values().next().value;
    processedItemIds.delete(oldestKey);
  }

  processedItemIds.add(key);
  return false;
}

// ============================================================================
// Utilidades de Archivos JSON Locales (Caché, Cookies y Filtros Calm Tech)
// ============================================================================
function readJsonFileSafe(filePath, fallbackValue) {
  try {
    if (!fs.existsSync(filePath)) {
      return fallbackValue;
    }
    const raw = fs.readFileSync(filePath, 'utf8').trim();
    if (!raw) return fallbackValue;
    return JSON.parse(raw);
  } catch (err) {
    console.warn(`[SCInsta-Listener] No se pudo leer ${path.basename(filePath)}: ${err.message}`);
    return fallbackValue;
  }
}

function loadUsersCache() {
  const loaded = readJsonFileSafe(USERS_CACHE_PATH, {});
  if (loaded && typeof loaded === 'object' && !Array.isArray(loaded)) {
    usersCache = loaded;
  } else {
    usersCache = {};
  }
}

function saveUsersCache() {
  try {
    fs.writeFileSync(USERS_CACHE_PATH, JSON.stringify(usersCache, null, 2), 'utf8');
  } catch (err) {
    console.error(`[SCInsta-Listener] Error guardando users_cache.json: ${err.message}`);
  }
}

function upsertUserInCache(userObj) {
  if (!userObj || typeof userObj !== 'object') return false;

  const rawIds = [
    userObj.pk,
    userObj.id,
    userObj.pk_id,
    userObj.user_id,
    userObj.interop_messaging_user_fbid
  ]
    .filter((v) => v !== undefined && v !== null && String(v).trim() !== '')
    .map((v) => String(v).trim());

  if (rawIds.length === 0) return false;

  const fullName = typeof userObj.full_name === 'string' ? userObj.full_name.trim() : '';
  const username = typeof userObj.username === 'string' ? userObj.username.trim() : '';
  const displayName = fullName || (username ? `@${username.replace(/^@/, '')}` : '');

  if (!displayName) return false;

  let changed = false;
  for (const id of rawIds) {
    const existing = usersCache[id];
    const entry = {
      name: displayName,
      full_name: fullName || null,
      username: username ? `@${username.replace(/^@/, '')}` : null,
      updatedAt: Date.now()
    };

    if (!existing || existing.name !== entry.name || existing.username !== entry.username) {
      usersCache[id] = entry;
      changed = true;
    }
  }

  return changed;
}

function getCachedSenderName(userId) {
  if (!userId) return null;
  const key = String(userId).trim();
  const entry = usersCache[key];
  if (!entry) return null;
  if (typeof entry === 'string') return entry;
  if (typeof entry === 'object') {
    return entry.name || entry.full_name || entry.username || null;
  }
  return null;
}

/**
 * Evalúa los filtros opcionales Calm Tech (muted_threads.json y whitelist.json).
 */
function passesCalmTechFilters({ threadId, userId, senderName }) {
  // 1. Verificar hilos silenciados (muted_threads.json)
  const mutedData = readJsonFileSafe(MUTED_THREADS_PATH, null);
  if (mutedData && threadId) {
    const mutedList = Array.isArray(mutedData)
      ? mutedData
      : Array.isArray(mutedData.threads)
        ? mutedData.threads
        : [];
    const normalizedMuted = mutedList.map((t) => String(t).trim());
    if (normalizedMuted.includes(String(threadId).trim())) {
      console.log(`[SCInsta-Listener] Hilo silenciado (${threadId}), omitiendo notificación.`);
      return false;
    }
  }

  // 2. Verificar lista blanca (whitelist.json)
  const whitelistData = readJsonFileSafe(WHITELIST_PATH, null);
  if (!whitelistData) return true;

  // Formato array directo: ["user_id", "@username", "thread_id"]
  if (Array.isArray(whitelistData)) {
    if (whitelistData.length === 0) return true;
    const allowedSet = new Set(whitelistData.map((v) => String(v).trim().toLowerCase()));
    const candidates = [
      userId ? String(userId).trim().toLowerCase() : '',
      threadId ? String(threadId).trim().toLowerCase() : '',
      senderName ? String(senderName).trim().toLowerCase() : '',
      senderName ? `@${String(senderName).trim().replace(/^@/, '').toLowerCase()}` : ''
    ].filter(Boolean);

    return candidates.some((c) => allowedSet.has(c));
  }

  // Formato objeto: { enabled: boolean, users: [], threads: [] }
  if (typeof whitelistData === 'object') {
    if (whitelistData.enabled === false) return true;

    const allowedUsers = Array.isArray(whitelistData.users)
      ? whitelistData.users.map((u) => String(u).trim().toLowerCase())
      : [];
    const allowedThreads = Array.isArray(whitelistData.threads)
      ? whitelistData.threads.map((t) => String(t).trim().toLowerCase())
      : [];

    if (allowedUsers.length === 0 && allowedThreads.length === 0) {
      return true;
    }

    if (threadId && allowedThreads.includes(String(threadId).trim().toLowerCase())) {
      return true;
    }

    const userCandidates = [
      userId ? String(userId).trim().toLowerCase() : '',
      senderName ? String(senderName).trim().toLowerCase() : '',
      senderName ? `@${String(senderName).trim().replace(/^@/, '').toLowerCase()}` : ''
    ].filter(Boolean);

    if (userCandidates.some((c) => allowedUsers.includes(c))) {
      return true;
    }

    console.log(`[SCInsta-Listener] Remitente/hilo no incluido en whitelist.json, omitiendo.`);
    return false;
  }

  return true;
}

// ============================================================================
// Envío de Webhook Interno al Push Server (Contrato B y Contrato C)
// PROHIBICIÓN ESTRICTA: Cero peticiones HTTP hacia dominios de Meta/Instagram.
// ============================================================================
async function sendWebhookNotification({ messageId, senderName, text, threadId, timestamp }) {
  const targetUrl = new URL(PUSH_WEBHOOK_URL);

  // Salvaguarda explícita de Contrato C: jamás hacer peticiones salientes a Meta
  const forbiddenHosts = ['instagram.com', 'facebook.com', 'fbcdn.net', 'meta.com'];
  if (forbiddenHosts.some((domain) => targetUrl.hostname.toLowerCase().includes(domain))) {
    throw new Error(`Violación de Contrato C bloqueada: destino prohibido ${targetUrl.hostname}`);
  }

  const payload = JSON.stringify({
    messageId: String(messageId),
    senderName: String(senderName || 'Instagram DM'),
    text: String(text || 'Nuevo mensaje'),
    threadId: threadId !== undefined && threadId !== null && String(threadId).trim() !== '' ? String(threadId) : null,
    timestamp: typeof timestamp === 'number' ? timestamp : Date.now()
  });

  const headers = {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
    Authorization: `Bearer ${WEBHOOK_SECRET}`
  };

  return new Promise((resolve) => {
    const transport = targetUrl.protocol === 'https:' ? https : http;
    const req = transport.request(
      targetUrl,
      {
        method: 'POST',
        headers,
        timeout: 8000
      },
      (res) => {
        let responseBody = '';
        res.on('data', (chunk) => {
          responseBody += chunk;
        });
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            console.log(
              `[SCInsta-Listener] Notificación enviada -> ${senderName} (threadId: ${threadId ?? 'null'}, id: ${messageId})`
            );
            resolve(true);
          } else {
            console.error(
              `[SCInsta-Listener] Push server respondió HTTP ${res.statusCode}: ${responseBody}`
            );
            resolve(false);
          }
        });
      }
    );

    req.on('error', (err) => {
      console.error(`[SCInsta-Listener] Error conectando a ${PUSH_WEBHOOK_URL}: ${err.message}`);
      resolve(false);
    });

    req.on('timeout', () => {
      req.destroy();
      console.error(`[SCInsta-Listener] Timeout enviando webhook a ${PUSH_WEBHOOK_URL}`);
      resolve(false);
    });

    req.write(payload);
    req.end();
  });
}

// ============================================================================
// Manejo de Sesión Expirada (Alerta única + detención de reconexión)
// ============================================================================
async function handleSessionExpired(reason) {
  if (sessionExpiredHandled) return;
  sessionExpiredHandled = true;
  stopReconnectionLoops = true;

  console.error(`[SCInsta-Listener] Sesión expirada detectada (${reason}). Enviando alerta única...`);

  await sendWebhookNotification({
    messageId: `system-session-expired-${Date.now()}`,
    senderName: 'SCInsta Sistema',
    text: 'Sesión expirada: actualiza cookies.json',
    threadId: null,
    timestamp: Date.now()
  });

  if (activeBrowser) {
    try {
      await activeBrowser.close();
    } catch (_) {
      // Ignorar errores al cerrar navegador
    }
    activeBrowser = null;
  }

  console.error('[SCInsta-Listener] Bucles de reconexión detenidos hasta que se actualice cookies.json.');
}

// ============================================================================
// 2. Resolución Pasiva de Identidad (Contrato C)
// ============================================================================
function extractUsersFromInboxOrThreadsJson(data) {
  if (!data || typeof data !== 'object') return;
  let updated = false;

  // Extraer usuario propio si viene en viewer
  if (data.viewer && (data.viewer.pk || data.viewer.id)) {
    ownUserId = String(data.viewer.pk || data.viewer.id);
    if (upsertUserInCache(data.viewer)) updated = true;
  }

  const processThread = (thread) => {
    if (!thread || typeof thread !== 'object') return;
    if (Array.isArray(thread.users)) {
      for (const user of thread.users) {
        if (upsertUserInCache(user)) updated = true;
      }
    }
    if (thread.inviter && typeof thread.inviter === 'object') {
      if (upsertUserInCache(thread.inviter)) updated = true;
    }
    if (Array.isArray(thread.left_users)) {
      for (const user of thread.left_users) {
        if (upsertUserInCache(user)) updated = true;
      }
    }
  };

  if (data.inbox && Array.isArray(data.inbox.threads)) {
    for (const thread of data.inbox.threads) {
      processThread(thread);
    }
  }

  if (data.thread && typeof data.thread === 'object') {
    processThread(data.thread);
  }

  if (Array.isArray(data.threads)) {
    for (const thread of data.threads) {
      processThread(thread);
    }
  }

  if (Array.isArray(data.users)) {
    for (const user of data.users) {
      if (upsertUserInCache(user)) updated = true;
    }
  }

  if (updated) {
    saveUsersCache();
  }
}

/**
 * Fallback pasivo vía DOM:
 * Si el user_id no está en users_cache.json, espera 800ms a que React actualice
 * la bandeja lateral y lee el primer elemento de div[role="list"] div[role="listitem"].
 * Si no figura (ej. Solicitudes ocultas), retorna "Nueva solicitud de mensaje".
 */
async function resolveSenderNamePassively(page, userId) {
  const cached = getCachedSenderName(userId);
  if (cached) {
    return cached;
  }

  try {
    await new Promise((resolve) => setTimeout(resolve, 800));

    if (!page || page.isClosed()) {
      return 'Nueva solicitud de mensaje';
    }

    const domSenderName = await page.evaluate(() => {
      const firstItem = document.querySelector('div[role="list"] div[role="listitem"]');
      if (!firstItem) return null;

      const rawText = (firstItem.innerText || firstItem.textContent || '').trim();
      if (!rawText) return null;

      const lines = rawText
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);

      if (lines.length === 0) return null;
      return lines[0];
    });

    if (domSenderName && domSenderName.length > 0 && domSenderName.length <= 80) {
      if (userId) {
        usersCache[String(userId).trim()] = {
          name: domSenderName,
          full_name: domSenderName,
          username: null,
          updatedAt: Date.now()
        };
        saveUsersCache();
      }
      return domSenderName;
    }
  } catch (err) {
    console.warn(`[SCInsta-Listener] Fallback DOM no disponible: ${err.message}`);
  }

  return 'Nueva solicitud de mensaje';
}

// ============================================================================
// 3. Decodificador WebSocket / MQTT (/ig_message_sync)
// ============================================================================

/**
 * Extrae bloques JSON válidos entre '{' y '}' limpiando caracteres de control ([\x00-\x1F]+).
 */
function extractJsonPayloadsFromMqttFrame(rawPayload) {
  const text = Buffer.isBuffer(rawPayload)
    ? rawPayload.toString('utf8')
    : typeof rawPayload === 'string'
      ? rawPayload
      : String(rawPayload || '');

  if (!text.includes('/ig_message_sync')) {
    return [];
  }

  const syncIndex = text.indexOf('/ig_message_sync');
  const afterTopic = text.slice(syncIndex + '/ig_message_sync'.length);

  // Limpiar caracteres de control [\x00-\x1F]+
  const cleaned = afterTopic.replace(/[\x00-\x1F]+/g, '');

  const parsedObjects = [];

  // Intento 1: recorte directo entre el primer '{' y el último '}'
  const firstBrace = cleaned.indexOf('{');
  const lastBrace = cleaned.lastIndexOf('}');
  if (firstBrace !== -1 && lastBrace > firstBrace) {
    const candidate = cleaned.slice(firstBrace, lastBrace + 1);
    try {
      const parsed = JSON.parse(candidate);
      parsedObjects.push(parsed);
      return parsedObjects;
    } catch (_) {
      // Si hay múltiples objetos JSON concatenados o un array envolvente, extraer por balance de llaves
    }
  }

  // Intento 2: extracción balanceada de cada bloque '{ ... }' válido
  let depth = 0;
  let startIdx = -1;
  let inString = false;
  let escaped = false;

  for (let i = 0; i < cleaned.length; i++) {
    const ch = cleaned[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === '{') {
      if (depth === 0) {
        startIdx = i;
      }
      depth++;
    } else if (ch === '}') {
      if (depth > 0) {
        depth--;
        if (depth === 0 && startIdx !== -1) {
          const chunk = cleaned.slice(startIdx, i + 1);
          try {
            parsedObjects.push(JSON.parse(chunk));
          } catch (_) {
            // Ignorar fragmentos corruptos
          }
          startIdx = -1;
        }
      }
    }
  }

  return parsedObjects;
}

/**
 * Normaliza un objeto decodificado de /ig_message_sync a una lista de deltas
 * que contienen únicamente mensajes nuevos con `delta.message` e `item_id` válido.
 */
function extractNewMessageDeltas(payloadObj) {
  const validDeltas = [];
  if (!payloadObj || typeof payloadObj !== 'object') return validDeltas;

  // Caso A: { deltas: [ { message: { item_id, ... }, thread_id } ] }
  if (Array.isArray(payloadObj.deltas)) {
    for (const delta of payloadObj.deltas) {
      if (delta && delta.message && delta.message.item_id) {
        validDeltas.push(delta);
      }
    }
  }

  // Caso B: el propio objeto es un delta con delta.message
  if (payloadObj.message && payloadObj.message.item_id) {
    validDeltas.push(payloadObj);
  }

  // Caso C: formato Iris patch { data: [ { op: 'add', path: '/direct_v2/threads/<threadId>/items/<itemId>', value: '...' } ] }
  if (Array.isArray(payloadObj.data)) {
    for (const opEntry of payloadObj.data) {
      if (!opEntry || typeof opEntry !== 'object') continue;

      if (opEntry.message && opEntry.message.item_id) {
        validDeltas.push(opEntry);
        continue;
      }

      if (opEntry.op !== 'add' || typeof opEntry.path !== 'string') continue;
      const match = opEntry.path.match(/^\/direct_v2\/threads\/([^/]+)\/items\/([^/]+)$/);
      if (!match) continue;

      const [, pathThreadId, pathItemId] = match;
      let msgValue = opEntry.value;
      if (typeof msgValue === 'string') {
        try {
          msgValue = JSON.parse(msgValue.replace(/[\x00-\x1F]+/g, ''));
        } catch (_) {
          continue;
        }
      }

      if (msgValue && typeof msgValue === 'object') {
        const itemId = msgValue.item_id || pathItemId;
        if (itemId) {
          validDeltas.push({
            thread_id: msgValue.thread_id || pathThreadId,
            message: {
              ...msgValue,
              item_id: itemId,
              thread_id: msgValue.thread_id || pathThreadId
            }
          });
        }
      }
    }
  }

  return validDeltas;
}

/**
 * Construye el texto legible del mensaje o resumen de adjunto.
 */
function formatMessageBody(message) {
  if (!message || typeof message !== 'object') return 'Nuevo mensaje';

  if (typeof message.text === 'string' && message.text.trim() !== '') {
    return message.text.trim();
  }

  const itemType = String(message.item_type || '').toLowerCase();
  switch (itemType) {
    case 'voice_media':
      return '🎵 Mensaje de voz';
    case 'media':
    case 'raven_media':
      return '📷 Foto o video';
    case 'media_share':
    case 'post_share':
      return '📌 Publicación compartida';
    case 'reel_share':
    case 'clip':
      return '🎬 Reel compartido';
    case 'story_share':
      return '📖 Historia compartida';
    case 'link':
      return (
        (message.link && message.link.text) ||
        '🔗 Enlace compartido'
      );
    case 'like':
      return '❤️';
    case 'animated_media':
      return 'GIF';
    default:
      return 'Nuevo mensaje en Instagram';
  }
}

async function processIncomingMessageDelta(page, delta) {
  if (!delta || !delta.message) return;

  const msg = delta.message;
  const itemId = msg.item_id || msg.id;
  if (!itemId) return;

  // Descartar eventos que no sean mensajes reales (ej. typing indicators, read receipts, action logs)
  const ignoredTypes = new Set(['action_log', 'typing_indicator', 'read_receipt', 'VideoCallEvent']);
  if (msg.item_type && ignoredTypes.has(String(msg.item_type))) {
    return;
  }
  if (msg.is_sent_by_viewer === true) {
    return;
  }

  const senderUserId = msg.user_id !== undefined && msg.user_id !== null ? String(msg.user_id) : null;

  // Ignorar mensajes enviados por nuestra propia cuenta
  if (ownUserId && senderUserId && senderUserId === String(ownUserId)) {
    return;
  }

  // Deduplicación en buffer circular de 500 item_id (Contrato C)
  if (isDuplicateMessage(itemId)) {
    return;
  }

  const threadId =
    delta.thread_id ||
    msg.thread_id ||
    (delta.thread_key && delta.thread_key.thread_id) ||
    null;

  // Resolver identidad pasivamente (users_cache.json -> DOM -> "Nueva solicitud de mensaje")
  const senderName = await resolveSenderNamePassively(page, senderUserId);
  const text = formatMessageBody(msg);

  let timestampMs = Date.now();
  if (msg.timestamp) {
    const rawTs = Number(msg.timestamp);
    if (!Number.isNaN(rawTs) && rawTs > 0) {
      // Los timestamps de Instagram suelen venir en microsegundos (16 dígitos)
      timestampMs = rawTs > 1e14 ? Math.floor(rawTs / 1000) : rawTs > 1e11 ? rawTs : rawTs * 1000;
    }
  }

  // Aplicar filtros opcionales Calm Tech (whitelist.json / muted_threads.json)
  if (!passesCalmTechFilters({ threadId, userId: senderUserId, senderName })) {
    return;
  }

  await sendWebhookNotification({
    messageId: String(itemId),
    senderName,
    text,
    threadId: threadId ? String(threadId) : null,
    timestamp: timestampMs
  });
}

// ============================================================================
// 1. Inicialización del Navegador Headless Ultra-Ligero y Ciclo de Escucha
// ============================================================================
function loadCookiesFromDisk() {
  if (!fs.existsSync(COOKIES_PATH)) {
    throw new Error(`Archivo de cookies no encontrado en ${COOKIES_PATH}`);
  }

  const rawCookies = JSON.parse(fs.readFileSync(COOKIES_PATH, 'utf8'));
  if (!Array.isArray(rawCookies) || rawCookies.length === 0) {
    throw new Error('cookies.json debe contener un array no vacío de cookies');
  }

  const dsUserCookie = rawCookies.find((c) => c && c.name === 'ds_user_id' && c.value);
  if (dsUserCookie) {
    ownUserId = String(dsUserCookie.value).trim();
  }

  return rawCookies.map((cookie) => ({
    name: String(cookie.name),
    value: String(cookie.value),
    domain: cookie.domain || '.instagram.com',
    path: cookie.path || '/',
    httpOnly: Boolean(cookie.httpOnly),
    secure: cookie.secure !== undefined ? Boolean(cookie.secure) : true,
    sameSite: ['Strict', 'Lax', 'None'].includes(cookie.sameSite) ? cookie.sameSite : 'None',
    ...(typeof cookie.expires === 'number' && cookie.expires > 0 ? { expires: cookie.expires } : {})
  }));
}

async function startListener() {
  loadUsersCache();

  let cookies;
  try {
    cookies = loadCookiesFromDisk();
  } catch (err) {
    console.error(`[SCInsta-Listener] Error cargando cookies: ${err.message}`);
    await handleSessionExpired(err.message);
    return;
  }

  console.log('[SCInsta-Listener] Iniciando Chromium Headless Ultra-Ligero...');
  const browser = await chromium.launch({
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--disable-extensions',
      '--blink-settings=imagesEnabled=false'
    ]
  });
  activeBrowser = browser;

  const context = await browser.newContext({
    userAgent: DESKTOP_USER_AGENT,
    viewport: { width: 1280, height: 800 }
  });

  await context.addCookies(cookies);
  const page = await context.newPage();

  // 1. Interceptar peticiones para abortar recursos pesados y telemetría
  await page.route('**/*', (route) => {
    const request = route.request();
    const resourceType = request.resourceType();
    const url = request.url().toLowerCase();

    if (ABORTED_RESOURCE_TYPES.has(resourceType)) {
      return route.abort();
    }

    if (ABORTED_TELEMETRY_PATTERNS.some((pattern) => url.includes(pattern))) {
      return route.abort();
    }

    return route.continue();
  });

  // 2. Captura pasiva de red (Contrato C: solo lectura de respuestas naturales del navegador)
  page.on('response', async (response) => {
    try {
      const url = response.url();
      if (
        url.includes('/api/v1/direct_v2/inbox') ||
        url.includes('/api/v1/direct_v2/threads/')
      ) {
        const status = response.status();
        if (status === 401 || status === 403) {
          await handleSessionExpired(`HTTP ${status} en ${url}`);
          return;
        }
        const contentType = response.headers()['content-type'] || '';
        if (contentType.includes('application/json')) {
          const jsonData = await response.json();
          extractUsersFromInboxOrThreadsJson(jsonData);
        }
      }
    } catch (_) {
      // Ignorar respuestas parciales o canceladas durante navegación
    }
  });

  // Detectar redirección a /accounts/login/ en cualquier momento
  page.on('framenavigated', async (frame) => {
    if (frame !== page.mainFrame()) return;
    const currentUrl = frame.url();
    if (currentUrl.includes('/accounts/login')) {
      await handleSessionExpired(`Redirección a ${currentUrl}`);
    }
  });

  // 3. Escuchar WebSockets filtrando edge-chat.instagram.com
  page.on('websocket', (ws) => {
    const wsUrl = ws.url();
    if (!wsUrl.includes('edge-chat.instagram.com')) {
      return;
    }

    console.log(`[SCInsta-Listener] WebSocket conectado: ${wsUrl}`);

    ws.on('framereceived', (frame) => {
      if (stopReconnectionLoops) return;
      try {
        const payloads = extractJsonPayloadsFromMqttFrame(frame.payload);
        for (const payloadObj of payloads) {
          const deltas = extractNewMessageDeltas(payloadObj);
          for (const delta of deltas) {
            processIncomingMessageDelta(page, delta).catch((err) => {
              console.error(`[SCInsta-Listener] Error procesando delta: ${err.message}`);
            });
          }
        }
      } catch (err) {
        console.error(`[SCInsta-Listener] Error decodificando frame MQTT: ${err.message}`);
      }
    });

    ws.on('socketerror', (errMsg) => {
      console.warn(`[SCInsta-Listener] Error en WebSocket edge-chat: ${errMsg}`);
      if (
        typeof errMsg === 'string' &&
        (errMsg.toLowerCase().includes('auth') ||
          errMsg.toLowerCase().includes('unauthorized') ||
          errMsg.includes('401') ||
          errMsg.includes('403'))
      ) {
        handleSessionExpired(`Error de autenticación WebSocket: ${errMsg}`);
      }
    });

    ws.on('close', async () => {
      if (stopReconnectionLoops) return;
      console.warn('[SCInsta-Listener] WebSocket edge-chat cerrado. Verificando estado de sesión...');

      try {
        if (!page.isClosed()) {
          const currentUrl = page.url();
          if (currentUrl.includes('/accounts/login')) {
            await handleSessionExpired('WebSocket cerrado por redirección a /accounts/login/');
            return;
          }

          // Verificar si las cookies de sesión fueron invalidadas por Instagram
          const currentCookies = await context.cookies('https://www.instagram.com');
          const hasSession = currentCookies.some(
            (c) => c.name === 'sessionid' && c.value && c.value !== '""'
          );
          if (!hasSession) {
            await handleSessionExpired('WebSocket cerrado y cookie sessionid eliminada');
          }
        }
      } catch (_) {
        // Página ya cerrada
      }
    });
  });

  console.log(`[SCInsta-Listener] Navegando a ${INSTAGRAM_INBOX_URL}...`);
  await page.goto(INSTAGRAM_INBOX_URL, {
    waitUntil: 'domcontentloaded',
    timeout: 60000
  });

  if (page.url().includes('/accounts/login')) {
    await handleSessionExpired(`Redirección inicial a ${page.url()}`);
    return;
  }

  console.log('[SCInsta-Listener] Escucha pasiva activa en bandeja de entrada.');
}

// ============================================================================
// Manejo de Señales del Sistema y Arranque
// ============================================================================
async function gracefulShutdown(signal) {
  console.log(`[SCInsta-Listener] Recibida señal ${signal}, cerrando navegador...`);
  stopReconnectionLoops = true;
  if (activeBrowser) {
    try {
      await activeBrowser.close();
    } catch (_) {
      // Ignorar
    }
  }
  process.exit(0);
}

process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));

startListener().catch(async (err) => {
  console.error(`[SCInsta-Listener] Error fatal en listener: ${err.message}`);
  if (activeBrowser) {
    try {
      await activeBrowser.close();
    } catch (_) {
      // Ignorar
    }
  }
  if (!stopReconnectionLoops) {
    process.exit(1);
  }
});
