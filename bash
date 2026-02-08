#!/usr/bin/env bash
# create_project.sh — أنشئ مشروع mic-consent-starter محليًا وادفعه إلى GitHub
set -e

GITHUB_USER="YOUR_GITHUB_USER"   # <-- ضع اسم حساب GitHub هنا
REPO_NAME="mic-consent-starter"
BACKEND_PORT=3000

if [ "$GITHUB_USER" = "YOUR_GITHUB_USER" ]; then
  echo "⚠️  عدّل GITHUB_USER في الملف إلى حساب GitHub الخاص بك ثم أعد التشغيل."
  exit 1
fi

if ! command -v gh &> /dev/null; then
  echo "gh CLI غير مثبت. ثبته: https://cli.github.com/ ثم شغّل 'gh auth login'."
  exit 1
fi

# Clean start
rm -rf ${REPO_NAME}
mkdir ${REPO_NAME}
cd ${REPO_NAME}

# .gitignore
cat > .gitignore <<'GIT'
node_modules/
dist/
.env
.DS_Store
GIT

# README
cat > README.md <<'MD'
# mic-consent-starter
Proof-of-concept: consented microphone streaming to server (WebSocket), PCM Int16, optional storage & ASR.
MD

# BACKEND
mkdir backend
cat > backend/server.js <<'JS'
// Node.js - Express + ws receiver (save raw PCM to files, basic consent API)
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');

const app = express();
app.use(express.json());

const DATA_DIR = path.join(__dirname, 'data');
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR);

app.get('/', (req, res) => res.send('mic-consent-starter backend alive'));

app.post('/consent', (req, res) => {
  const rec = { ts: Date.now(), body: req.body };
  fs.appendFileSync(path.join(DATA_DIR, 'consents.jsonl'), JSON.stringify(rec) + '\n');
  res.json({ ok: true });
});

const server = http.createServer(app);
const wss = new WebSocket.Server({ server, path: '/ws-audio' });

wss.on('connection', (ws, req) => {
  console.log('audio client connected');
  const fname = path.join(DATA_DIR, `recv_${Date.now()}.raw`);
  ws.on('message', (msg) => {
    const buf = Buffer.from(msg);
    fs.appendFile(fname, buf, (err) => { if (err) console.error(err); });
  });
  ws.on('close', () => console.log('client disconnected'));
});

server.listen(process.env.PORT || ${BACKEND_PORT}, () => console.log('Server listening on :${BACKEND_PORT}'));
JS

cat > backend/package.json <<'PJ'
{
  "name": "mic-backend",
  "version": "1.0.0",
  "main": "server.js",
  "license": "MIT",
  "dependencies": {
    "express": "^4.18.2",
    "ws": "^8.13.0"
  },
  "scripts": {
    "start": "node server.js"
  }
}
PJ

# FRONTEND (Vite React)
echo "Initializing Vite React app..."
npm init vite@latest frontend -- --template react >/dev/null 2>&1 || true

cat > frontend/src/main.jsx <<'REACT'
import React, { useState, useRef } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";

function App() {
  const [running, setRunning] = useState(false);
  const wsRef = useRef(null);
  const procRef = useRef(null);
  const ctxRef = useRef(null);

  async function start() {
    if (running) return;
    const allowed = confirm("هل تسمح لهذا الموقع بالاستماع للميكروفون بشكل مستمر بعد الموافقة؟");
    if (!allowed) return;
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      ctxRef.current = audioCtx;
      const src = audioCtx.createMediaStreamSource(stream);
      const proc = audioCtx.createScriptProcessor(4096, 1, 1);
      proc.onaudioprocess = (e) => {
        const input = e.inputBuffer.getChannelData(0);
        const buffer = new ArrayBuffer(input.length * 2);
        const view = new DataView(buffer);
        let offset = 0;
        for (let i = 0; i < input.length; i++, offset += 2) {
          let s = Math.max(-1, Math.min(1, input[i]));
          view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
        }
        if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
          wsRef.current.send(buffer);
        }
      };
      src.connect(proc);
      proc.connect(audioCtx.destination);
      procRef.current = proc;

      // dynamic WS URL (dev/prod safe)
      const envWsBase = window.__ENV?.REACT_APP_WS_URL || null;
      const defaultOrigin = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host;
      const wsBase = envWsBase || defaultOrigin;
      const WS_URL = wsBase.endsWith('/ws-audio') ? wsBase : wsBase + '/ws-audio';
      const ws = new WebSocket(WS_URL);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => console.log("ws open", WS_URL);
      wsRef.current = ws;

      localStorage.setItem("micConsent", JSON.stringify({ granted: true, ts: Date.now() }));
      fetch('/consent', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({granted:true, ts:Date.now()}) }).catch(()=>{});
      setRunning(true);
    } catch (err) {
      alert('Error accessing microphone: ' + err.message);
    }
  }

  function stop() {
    if (!running) return;
    if (procRef.current) { procRef.current.disconnect(); procRef.current = null; }
    if (ctxRef.current) { ctxRef.current.close(); ctxRef.current = null; }
    if (wsRef.current) { wsRef.current.close(); wsRef.current = null; }
    localStorage.setItem("micConsent", JSON.stringify({ granted: false, ts: Date.now() }));
    fetch('/consent', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({granted:false, ts:Date.now()}) }).catch(()=>{});
    setRunning(false);
  }

  return (
    <div style={{padding:20}}>
      <h3>منصة mic-consent-starter (مع موافقة)</h3>
      <button onClick={start} disabled={running}>ابدأ (موافقة)</button>
      <button onClick={stop} disabled={!running}>أوقف</button>
      <p>الموافقة محفوظة محليًا ومرسلة للخادم.</p>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
REACT

cat > frontend/index.html <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>mic-consent-starter</title>
  </head>
  <body>
    <div id="root"></div>
    <script>
      // Bridge for runtime env injection on static hosts (Vercel/GCP). You can set REACT_APP_WS_URL in hosting env.
      window.__ENV = {};
    </script>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
HTML

cat > frontend/src/style.css <<'CSS'
body { font-family: Arial, sans-serif; }
button { margin-right: 8px; padding: 8px 12px; }
CSS

# default package.json for monorepo quick-run
cat > package.json <<'PJ'
{
  "name": "mic-consent-starter",
  "private": true,
  "workspaces": ["frontend", "backend"]
}
PJ

# Git init & commit
git init
git add .
git commit -m "Initial commit - mic-consent-starter POC"

echo "Creating GitHub repo ${GITHUB_USER}/${REPO_NAME} ..."
gh repo create ${GITHUB_USER}/${REPO_NAME} --public --source=. --remote=origin --push

echo "Installing backend dependencies (non-blocking)..."
cd backend
npm install --silent || true
cd ..

echo "✅ Done. Next steps printed below."
echo ""
echo "Run backend locally:"
echo "  cd ${REPO_NAME}/backend && npm start"
echo "Run frontend dev locally:"
echo "  cd ${REPO_NAME}/frontend && npm install && npm run dev"
echo ""
echo "To build frontend for production:"
echo "  cd ${REPO_NAME}/frontend && npm install && npm run build"
echo ""
echo "Deployment hints:"
echo "- For frontend (Vite) set Project Root to 'frontend' and Output Directory to 'dist' on Vercel/Netlify."
echo "- For backend deploy to Render/Heroku with start command: 'node server.js'"
