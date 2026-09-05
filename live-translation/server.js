// Live Translation (English -> Marathi) - tiny zero-dependency server.
//
// Responsibilities:
//   1. Serve the static web app from ./public
//   2. GET /api/token  -> mint a short-lived Azure Speech token so the
//      subscription key never leaves this server.
//
// Requires Node 18+ (built-in fetch). No npm install needed.

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

loadDotEnv(path.join(__dirname, ".env"));

const PORT = Number(process.env.PORT || 3000);
const KEY = process.env.AZURE_SPEECH_KEY;
const REGION = process.env.AZURE_SPEECH_REGION;
const APP_PIN = process.env.APP_PIN || ""; // optional: protects /api/token
const PUBLIC_DIR = path.join(__dirname, "public");

if (!KEY || !REGION) {
  console.error(
    "Missing AZURE_SPEECH_KEY / AZURE_SPEECH_REGION. Copy .env.example to .env and fill it in."
  );
  process.exit(1);
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
};

// Azure tokens live for 10 minutes. Cache one server-side for 8 minutes so a
// handful of phones share it instead of hammering the token endpoint.
let cached = { token: null, expiresAt: 0 };
async function getToken() {
  const now = Date.now();
  if (cached.token && cached.expiresAt - now > 60_000) return cached;
  const res = await fetch(
    `https://${REGION}.api.cognitive.microsoft.com/sts/v1.0/issueToken`,
    { method: "POST", headers: { "Ocp-Apim-Subscription-Key": KEY } }
  );
  if (!res.ok) {
    throw new Error(`Azure token request failed: ${res.status} ${await res.text()}`);
  }
  cached = { token: await res.text(), expiresAt: now + 8 * 60_000 };
  return cached;
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { "Cache-Control": "no-store", ...headers });
  res.end(body);
}

function sendJson(res, status, obj) {
  send(res, status, JSON.stringify(obj), {
    "Content-Type": "application/json; charset=utf-8",
  });
}

async function handleToken(req, res, url) {
  if (APP_PIN) {
    const pin = req.headers["x-app-pin"] || url.searchParams.get("pin") || "";
    if (pin !== APP_PIN) return sendJson(res, 401, { error: "bad_pin" });
  }
  try {
    const { token, expiresAt } = await getToken();
    sendJson(res, 200, {
      token,
      region: REGION,
      // Tell the client when to ask again (seconds from now).
      refreshInSec: Math.max(30, Math.floor((expiresAt - Date.now()) / 1000) - 30),
    });
  } catch (err) {
    console.error(err);
    sendJson(res, 502, { error: "token_failed", detail: String(err.message || err) });
  }
}

function serveStatic(res, urlPath) {
  let rel = decodeURIComponent(urlPath);
  if (rel === "/") rel = "/index.html";
  const file = path.normalize(path.join(PUBLIC_DIR, rel));
  if (!file.startsWith(PUBLIC_DIR + path.sep) && file !== PUBLIC_DIR) {
    return send(res, 403, "Forbidden");
  }
  fs.readFile(file, (err, data) => {
    if (err) return send(res, 404, "Not found");
    const ext = path.extname(file).toLowerCase();
    const headers = { "Content-Type": MIME[ext] || "application/octet-stream" };
    // Vendor bundle is versioned in its filename, so it can be cached hard.
    if (rel.startsWith("/vendor/")) headers["Cache-Control"] = "public, max-age=31536000, immutable";
    res.writeHead(200, headers);
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "GET" && url.pathname === "/api/token") return handleToken(req, res, url);
  if (req.method === "GET" && url.pathname === "/healthz") return send(res, 200, "ok");
  if (req.method === "GET" || req.method === "HEAD") return serveStatic(res, url.pathname);
  send(res, 405, "Method not allowed");
});

server.listen(PORT, () => {
  console.log(`Live translation server on http://localhost:${PORT} (region ${REGION}${APP_PIN ? ", PIN enabled" : ""})`);
});

// Minimal .env loader (KEY=VALUE per line, # comments) so we avoid a dependency.
function loadDotEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!m || line.trim().startsWith("#")) continue;
    let v = m[2];
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (process.env[m[1]] === undefined) process.env[m[1]] = v;
  }
}
