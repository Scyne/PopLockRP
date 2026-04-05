#!/usr/bin/env node

// ─── PopLock API Server ───────────────────────────────────────────────────────
// Single-file, zero-dependency HTTP API for the PopLock Minecraft server.
// Read endpoints are public. Write endpoints require X-API-Key header.
//
// Config: /etc/poplock-api.conf
//   API_KEY=your_secret_key_here
//   PORT=6767
//
// Usage: node /usr/local/bin/poplock-api.js

'use strict';

const http         = require('http');
const fs           = require('fs');
const path         = require('path');
const { exec, execSync } = require('child_process');

// ─── Load Config ─────────────────────────────────────────────────────────────

const CONFIG_FILE = '/etc/poplock-api.conf';

function loadConfig() {
  const defaults = { API_KEY: '', PORT: '6767' };
  if (!fs.existsSync(CONFIG_FILE)) return defaults;
  const lines = fs.readFileSync(CONFIG_FILE, 'utf8').split('\n');
  for (const line of lines) {
    const [k, ...v] = line.trim().split('=');
    if (k && v.length) defaults[k.trim()] = v.join('=').trim();
  }
  return defaults;
}

const config  = loadConfig();
const PORT    = parseInt(process.env.PORT    || config.PORT    || '6767', 10);
const API_KEY =          process.env.API_KEY || config.API_KEY || '';

if (!API_KEY) {
  console.warn('[WARN] No API_KEY set — write endpoints are disabled until one is configured.');
}

// ─── Server Paths (mirrors serv script variables) ─────────────────────────────

const MINECRAFT_DIR  = '/usr/local/games/minecraft_server/java';
const ARCHIVE_DIR    = `${MINECRAFT_DIR}/backups`;
const LOG_DIR        = `${MINECRAFT_DIR}/logs`;
const WHITELIST_FILE = `${MINECRAFT_DIR}/whitelist.json`;
const PROPS_FILE     = `${MINECRAFT_DIR}/server.properties`;
const SERVER_JAR     = 'server.jar';
const TMUX_SOCKET    = '/tmp/minecraft-tmux';
const SESSION_NAME   = 'minecraft';
const SERV_BIN       = '/usr/local/bin/serv';
const REPORT_BIN     = '/usr/local/bin/servreport.sh';
const SNAPSHOT_LOG   = '/var/log/minecraft_snapshot.log';

// ─── Helpers ─────────────────────────────────────────────────────────────────

function run(cmd) {
  return new Promise((resolve, reject) => {
    exec(cmd, { timeout: 15000 }, (err, stdout, stderr) => {
      if (err) reject(new Error(stderr || err.message));
      else resolve(stdout.trim());
    });
  });
}

function isServerRunning() {
  try {
    execSync(`pgrep -f "java.*-jar ${SERVER_JAR}"`, { stdio: 'ignore' });
    return true;
  } catch { return false; }
}

function readJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return null; }
}

function tailFile(file, lines = 100) {
  if (!fs.existsSync(file)) return null;
  try {
    return execSync(`tail -n ${lines} "${file}"`).toString();
  } catch { return null; }
}

function backupType(name) {
  if (name.startsWith('snapshot_'))         return 'snapshot';
  if (name.startsWith('minecraft_backup_')) return 'full_backup';
  if (name.startsWith('restore_undo'))      return 'restore_undo';
  return 'archive';
}

function formatBytes(bytes) {
  if (bytes < 1024)       return `${bytes} B`;
  if (bytes < 1048576)    return `${(bytes/1024).toFixed(1)} KB`;
  if (bytes < 1073741824) return `${(bytes/1048576).toFixed(1)} MB`;
  return `${(bytes/1073741824).toFixed(2)} GB`;
}

// ─── Auth ─────────────────────────────────────────────────────────────────────

function isAuthed(req) {
  if (!API_KEY) return false;
  const key = req.headers['x-api-key'] || '';
  return key === API_KEY;
}

// ─── Response Helpers ─────────────────────────────────────────────────────────

function json(res, data, status = 200) {
  const body = JSON.stringify(data, null, 2);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

function text(res, body, status = 200) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(body);
}

function err(res, message, status = 400) {
  json(res, { ok: false, error: message }, status);
}

function denied(res) {
  err(res, 'Unauthorized — X-API-Key required for write endpoints.', 401);
}

function bodyJSON(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => { body += chunk; if (body.length > 4096) reject(new Error('Body too large')); });
    req.on('end', () => {
      try { resolve(JSON.parse(body || '{}')); }
      catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

// ─── Route Handlers ───────────────────────────────────────────────────────────

// GET /  →  plain text servreport output
async function handleRoot(req, res) {
  try {
    const output = await run(`bash ${REPORT_BIN}`);
    text(res, output);
  } catch (e) {
    text(res, `Error running servreport: ${e.message}`, 500);
  }
}

// GET /api/status
async function handleStatus(req, res) {
  const running = isServerRunning();
  const data = { ok: true, online: running };

  if (running) {
    try {
      const pid = execSync(`pgrep -f "java.*-jar ${SERVER_JAR}"`).toString().trim().split('\n')[0];
      data.pid    = parseInt(pid, 10);
      data.uptime = execSync(`ps -o etime= -p ${pid}`).toString().trim();
      data.memory = execSync(`ps -o %mem= -p ${pid}`).toString().trim() + '%';
    } catch {}

    const vh = readJSON(`${MINECRAFT_DIR}/version_history.json`);
    if (vh?.currentVersion) data.version = vh.currentVersion;
  }

  json(res, data);
}

// GET /api/players/online
async function handlePlayersOnline(req, res) {
  if (!isServerRunning()) return json(res, { ok: true, online: false, players: [] });
  try {
    const logLines = tailFile(`${LOG_DIR}/latest.log`, 2000) || '';
    const sessions = {};
    for (const line of logLines.split('\n')) {
      const join  = line.match(/INFO\]: (\S+) joined the game/);
      const leave = line.match(/INFO\]: (\S+) (left the game|lost connection)/);
      if (join)  sessions[join[1]]  = 'online';
      if (leave) sessions[leave[1]] = 'offline';
    }
    const players = Object.entries(sessions)
      .filter(([, s]) => s === 'online')
      .map(([name]) => name);
    json(res, { ok: true, online: true, count: players.length, players });
  } catch (e) {
    err(res, e.message, 500);
  }
}

// GET /api/players/whitelist
function handleWhitelist(req, res) {
  const wl = readJSON(WHITELIST_FILE);
  if (!wl) return err(res, 'whitelist.json not found or unreadable', 404);
  json(res, { ok: true, count: wl.length, whitelist: wl });
}

// GET /api/logs/latest?lines=200
function handleLogLatest(req, res, query) {
  const lines = Math.min(parseInt(query.lines || '200', 10), 2000);
  const content = tailFile(`${LOG_DIR}/latest.log`, lines);
  if (content === null) return err(res, 'latest.log not found', 404);
  json(res, { ok: true, file: 'latest.log', lines: content.split('\n') });
}

// GET /api/logs/snapshot?lines=200
function handleLogSnapshot(req, res, query) {
  const lines = Math.min(parseInt(query.lines || '200', 10), 2000);
  const content = tailFile(SNAPSHOT_LOG, lines);
  if (content === null) return err(res, 'snapshot log not found', 404);
  json(res, { ok: true, file: SNAPSHOT_LOG, lines: content.split('\n') });
}

// GET /api/backups
function handleBackups(req, res) {
  if (!fs.existsSync(ARCHIVE_DIR)) return err(res, 'Backup directory not found', 404);
  const files = fs.readdirSync(ARCHIVE_DIR)
    .filter(f => f.endsWith('.tar.gz'))
    .map(f => {
      const full = path.join(ARCHIVE_DIR, f);
      const stat = fs.statSync(full);
      return {
        name:    f,
        type:    backupType(f),
        size:    formatBytes(stat.size),
        bytes:   stat.size,
        created: stat.mtime.toISOString(),
      };
    })
    .sort((a, b) => new Date(b.created) - new Date(a.created));

  json(res, { ok: true, count: files.length, backups: files });
}

// GET /api/report  →  JSON version of servreport data
async function handleReport(req, res) {
  try {
    const raw = await run(`bash ${REPORT_BIN}`);
    json(res, { ok: true, report: raw });
  } catch (e) {
    err(res, e.message, 500);
  }
}

// GET /api/properties  →  server.properties as key/value object
function handleProperties(req, res) {
  if (!fs.existsSync(PROPS_FILE)) return err(res, 'server.properties not found', 404);
  const lines = fs.readFileSync(PROPS_FILE, 'utf8').split('\n');
  const props = {};
  for (const line of lines) {
    if (line.startsWith('#') || !line.includes('=')) continue;
    const [k, ...v] = line.split('=');
    props[k.trim()] = v.join('=').trim();
  }
  json(res, { ok: true, properties: props });
}

// ── Write Endpoints ───────────────────────────────────────────────────────────

// POST /api/server/start
async function handleStart(req, res) {
  try {
    await run(`${SERV_BIN} start`);
    json(res, { ok: true, message: 'Server start command issued.' });
  } catch (e) { err(res, e.message, 500); }
}

// POST /api/server/stop
// serv stop waits up to 30s for graceful shutdown — fire and forget.
function handleStop(req, res) {
  if (!isServerRunning()) {
    return json(res, { ok: true, message: 'Server is already offline.' });
  }
  exec(`${SERV_BIN} stop >> ${SNAPSHOT_LOG} 2>&1 &`);
  json(res, { ok: true, message: 'Server stop command issued.' });
}

// POST /api/server/restart
// serv restart sleeps 10s internally — fire and forget.
function handleRestart(req, res) {
  exec(`${SERV_BIN} restart >> ${SNAPSHOT_LOG} 2>&1 &`);
  json(res, { ok: true, message: 'Server restart command issued.' });
}

// POST /api/command  body: { "command": "say hello" }
async function handleCommand(req, res) {
  let body;
  try { body = await bodyJSON(req); } catch (e) { return err(res, e.message); }
  const cmd = (body.command || '').trim();
  if (!cmd) return err(res, '"command" field is required.');

  if (/[;&|`$(){}[\]<>\\]/.test(cmd)) {
    return err(res, 'Command contains disallowed characters.');
  }

  try {
    await run(`tmux -S "${TMUX_SOCKET}" send-keys -t "${SESSION_NAME}" C-u "${cmd}" Enter`);
    json(res, { ok: true, message: `Command sent: ${cmd}` });
  } catch (e) { err(res, e.message, 500); }
}

// POST /api/whitelist/add  body: { "player": "Scyne" }
async function handleWhitelistAdd(req, res) {
  let body;
  try { body = await bodyJSON(req); } catch (e) { return err(res, e.message); }
  const player = (body.player || '').trim();
  if (!player || !/^[a-zA-Z0-9_]{1,16}$/.test(player)) {
    return err(res, 'Invalid player name.');
  }
  try {
    await run(`tmux -S "${TMUX_SOCKET}" send-keys -t "${SESSION_NAME}" C-u "whitelist add ${player}" Enter`);
    json(res, { ok: true, message: `${player} added to whitelist.` });
  } catch (e) { err(res, e.message, 500); }
}

// POST /api/whitelist/remove  body: { "player": "Scyne" }
async function handleWhitelistRemove(req, res) {
  let body;
  try { body = await bodyJSON(req); } catch (e) { return err(res, e.message); }
  const player = (body.player || '').trim();
  if (!player || !/^[a-zA-Z0-9_]{1,16}$/.test(player)) {
    return err(res, 'Invalid player name.');
  }
  try {
    await run(`tmux -S "${TMUX_SOCKET}" send-keys -t "${SESSION_NAME}" C-u "whitelist remove ${player}" Enter`);
    json(res, { ok: true, message: `${player} removed from whitelist.` });
  } catch (e) { err(res, e.message, 500); }
}

// POST /api/backup  →  triggers serv backup -s (silent, non-blocking)
function handleBackupTrigger(req, res) {
  exec(`${SERV_BIN} backup -s >> ${SNAPSHOT_LOG} 2>&1 &`);
  json(res, { ok: true, message: 'Backup triggered. Check /api/backups shortly.' });
}

// ─── Router ───────────────────────────────────────────────────────────────────

const ROUTES = {
  // Read
  'GET /':                      { fn: handleRoot,          auth: false },
  'GET /api/status':            { fn: handleStatus,        auth: false },
  'GET /api/players/online':    { fn: handlePlayersOnline, auth: false },
  'GET /api/players/whitelist': { fn: handleWhitelist,     auth: false },
  'GET /api/logs/latest':       { fn: handleLogLatest,     auth: false },
  'GET /api/logs/snapshot':     { fn: handleLogSnapshot,   auth: false },
  'GET /api/backups':           { fn: handleBackups,       auth: false },
  'GET /api/report':            { fn: handleReport,        auth: false },
  'GET /api/properties':        { fn: handleProperties,    auth: false },

  // Write (API key required)
  'POST /api/server/start':     { fn: handleStart,           auth: true },
  'POST /api/server/stop':      { fn: handleStop,            auth: true },
  'POST /api/server/restart':   { fn: handleRestart,         auth: true },
  'POST /api/command':          { fn: handleCommand,         auth: true },
  'POST /api/whitelist/add':    { fn: handleWhitelistAdd,    auth: true },
  'POST /api/whitelist/remove': { fn: handleWhitelistRemove, auth: true },
  'POST /api/backup':           { fn: handleBackupTrigger,   auth: true },
};

// GET /api  →  endpoint index
function handleIndex(req, res) {
  const endpoints = Object.entries(ROUTES).map(([key, val]) => {
    const [method, route] = key.split(' ');
    return { method, route, auth_required: val.auth };
  });
  json(res, { ok: true, service: 'PopLock API', version: '1.0.0', endpoints });
}

// ─── Server ───────────────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  const urlObj   = new URL(req.url, `http://localhost`);
  const pathname = urlObj.pathname.replace(/\/$/, '') || '/';
  const query    = Object.fromEntries(urlObj.searchParams);
  const method   = req.method.toUpperCase();

  console.log(`[${new Date().toISOString()}] ${method} ${pathname}`);

  if (method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin':  '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, X-API-Key',
    });
    return res.end();
  }

  if (method === 'GET' && (pathname === '/api' || pathname === '/api/')) {
    return handleIndex(req, res);
  }

  const routeKey = `${method} ${pathname}`;
  const route = ROUTES[routeKey];

  if (!route) {
    return err(res, `No route for ${method} ${pathname}`, 404);
  }

  if (route.auth && !isAuthed(req)) {
    return denied(res);
  }

  try {
    await route.fn(req, res, query);
  } catch (e) {
    console.error(`[ERROR] ${routeKey}:`, e.message);
    err(res, 'Internal server error', 500);
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[PopLock API] Listening on http://0.0.0.0:${PORT}`);
  console.log(`[PopLock API] Write endpoints: ${API_KEY ? 'ENABLED (key set)' : 'DISABLED (no key configured)'}`);
  console.log(`[PopLock API] Config: ${CONFIG_FILE}`);
});

server.on('error', (e) => {
  console.error('[FATAL]', e.message);
  process.exit(1);
});
