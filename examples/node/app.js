// Beispiel-Webapp für das Image node: node:http plus eine Abhängigkeit (ms) aus npm ci.
//
// Erfüllt den Laufzeitvertrag aller Beispiel-Apps (shared/tests/test-runtime.sh):
// Port 8080, /healthz, Unterbefehl "healthcheck", HTTPS-Request beim Start,
// Zeitzone Europe/Berlin, sauberes Beenden bei SIGTERM.
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const ms = require('ms');

const PORT = 8080;
const HEALTH_URL = `http://127.0.0.1:${PORT}/healthz`;
const STARTUP_URL = process.env.STARTUP_URL || 'https://example.com/';
const TIME_ZONE = 'Europe/Berlin';

const started = Date.now();
const indexHtml = fs.readFileSync(path.join(__dirname, 'index.html'));

function log(level, msg, fields = {}) {
  const extra = Object.entries(fields)
    .map(([k, v]) => ` ${k}=${JSON.stringify(String(v))}`)
    .join('');
  console.log(`time=${new Date().toISOString()} level=${level} msg=${JSON.stringify(msg)}${extra}`);
}

// RFC 3339 mit Offset der Zeitzone, z. B. 2026-10-26T15:53:33+01:00
function localTime(date, timeZone) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', {
      timeZone,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
      hourCycle: 'h23', timeZoneName: 'longOffset',
    }).formatToParts(date).map((p) => [p.type, p.value]),
  );
  const offset = parts.timeZoneName === 'GMT' ? '+00:00' : parts.timeZoneName.slice(3);
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}${offset}`;
}

async function healthcheck() {
  try {
    const res = await fetch(HEALTH_URL, { signal: AbortSignal.timeout(2000) });
    return res.ok ? 0 : 1;
  } catch {
    return 1;
  }
}

// Belegt, dass das CA-Bundle des Images funktioniert.
async function checkHTTPS(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
  await res.arrayBuffer();
  if (res.status >= 500) throw new Error(`status ${res.status}`);
}

function handle(req, res) {
  if (req.method !== 'GET') {
    res.writeHead(405).end();
  } else if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      runtime: `node ${process.version}`,
      uid: process.getuid(),
      gid: process.getgid(),
      tz: TIME_ZONE,
      local_time: localTime(new Date(), TIME_ZONE),
      uptime: ms(Date.now() - started),
    }));
  } else if (req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(indexHtml);
  } else {
    res.writeHead(404).end();
  }
}

async function main() {
  try {
    await checkHTTPS(STARTUP_URL);
  } catch (err) {
    log('ERROR', 'abbruch', { err: `startup https ${STARTUP_URL}: ${err.cause?.message ?? err.message}` });
    process.exit(1);
  }
  log('INFO', 'startup https ok', { url: STARTUP_URL });

  const server = http.createServer(handle);
  server.listen(PORT, () => log('INFO', 'listening', { addr: `:${PORT}` }));

  const shutdown = () => {
    log('INFO', 'shutdown requested');
    server.close(() => {
      log('INFO', 'shutdown complete');
      process.exit(0);
    });
    server.closeIdleConnections();
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
}

if (process.argv[2] === 'healthcheck') {
  healthcheck().then((code) => process.exit(code));
} else {
  main();
}
