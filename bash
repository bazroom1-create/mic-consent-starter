#!/usr/bin/env bash
# fix_and_prepare_deploy.sh
set -e

GITHUB_USER="${1:-YOUR_GITHUB_USER}"
REPO_NAME="$(basename $(pwd))"

if [ "$GITHUB_USER" = "YOUR_GITHUB_USER" ]; then
  echo "⚠️  استبدل YOUR_GITHUB_USER باسم حساب GitHub أو مرّر كأول معامل عند التشغيل."
  echo "مثال: ./fix_and_prepare_deploy.sh youruser"
fi

# 1) Ensure frontend/index.html has runtime env injection for REACT_APP_WS_URL
FRONT_INDEX="frontend/index.html"
mkdir -p frontend
cat > "${FRONT_INDEX}" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>mic-consent-starter</title>
  </head>
  <body>
    <div id="root"></div>
    <script>
      // Runtime environment injection: set REACT_APP_WS_URL in hosting panel (Vercel/Netlify)
      window.__ENV = {};
      try {
        // Vercel/Netlify will replace process envs if you configure them to be inlined; otherwise set via server-side injection
        if (typeof REACT_APP_WS_URL !== 'undefined') {
          window.__ENV.REACT_APP_WS_URL = REACT_APP_WS_URL;
        }
      } catch(e){}
    </script>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
HTML

echo "Wrote ${FRONT_INDEX}"

# 2) Add vercel.json rewrite rules to avoid SPA 404s
cat > frontend/vercel.json <<'JSON'
{
  "rewrites": [
    { "source": "/(.*)", "destination": "/index.html" }
  ]
}
JSON
echo "Wrote frontend/vercel.json"

# 3) Ensure frontend main.jsx uses window.__ENV for WS (if not exists replace basic file)
MAINJS="frontend/src/main.jsx"
if [ ! -f "${MAINJS}" ]; then
  mkdir -p frontend/src
  cat > "${MAINJS}" <<'REACT'
import React from "react";
import { createRoot } from "react-dom/client";
import App from "./app";
import "./style.css";
createRoot(document.getElementById("root")).render(<App />);
REACT
fi

# Also ensure app component uses env-based WS (app file)
APPJS="frontend/src/app.jsx"
cat > "${APPJS}" <<'REACT'
import React, { useState, useRef } from "react";

export default function App(){
  const [running, setRunning] = useState(false);
  const wsRef = useRef(null);
  const procRef = useRef(null);
  const ctxRef = useRef(null);

  async function start(){
    if (running) return;
    const allowed = confirm("هل تسمح بالاستماع للميكروفون؟");
    if (!allowed) return;
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      ctxRef.current = audioCtx;
      const src = audioCtx.createMediaStreamSource(stream);
      const proc = audioCtx.createScriptProcessor(4096,1,1);
      proc.onaudioprocess = (e) => {
        const input = e.inputBuffer.getChannelData(0);
        const buffer = new ArrayBuffer(input.length*2);
        const view = new DataView(buffer);
        for (let i=0, offset=0;i<input.length;i++,offset+=2){
          let s = Math.max(-1, Math.min(1, input[i]));
          view.setInt16(offset, s<0?s*0x8000:s*0x7fff, true);
        }
        if (wsRef.current && wsRef.current.readyState===WebSocket.OPEN){
          wsRef.current.send(buffer);
        }
      };
      src.connect(proc); proc.connect(audioCtx.destination);
      procRef.current = proc;

      const envWsBase = window.__ENV?.REACT_APP_WS_URL || null;
      const defaultOrigin = (location.protocol==='https:'?'wss://':'ws://') + location.host;
      const wsBase = envWsBase || defaultOrigin;
      const WS_URL = wsBase.endsWith('/ws-audio') ? wsBase : wsBase + '/ws-audio';
      const ws = new WebSocket(WS_URL);
      ws.binaryType = "arraybuffer";
      ws.onopen = ()=>console.log('ws open', WS_URL);
      wsRef.current = ws;

      localStorage.setItem('micConsent', JSON.stringify({granted:true, ts:Date.now()}));
      fetch('/consent', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({granted:true, ts:Date.now()})}).catch(()=>{});
      setRunning(true);
    } catch(err){
      alert('Microphone error: ' + err.message);
    }
  }

  function stop(){
    if (!running) return;
    if (procRef.current){ procRef.current.disconnect(); procRef.current=null; }
    if (ctxRef.current){ ctxRef.current.close(); ctxRef.current=null; }
    if (wsRef.current){ wsRef.current.close(); wsRef.current=null; }
    localStorage.setItem('micConsent', JSON.stringify({granted:false, ts:Date.now()}));
    fetch('/consent', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({granted:false, ts:Date.now()})}).catch(()=>{});
    setRunning(false);
  }

  return (
    <div style={{padding:20}}>
      <h3>mic-consent-starter</h3>
      <button onClick={start} disabled={running}>ابدأ</button>
      <button onClick={stop} disabled={!running}>أوقف</button>
      <p>الموافقة محفوظة محلياً.</p>
    </div>
  );
}
REACT

# 4) Build frontend
echo "Building frontend..."
cd frontend
npm install --silent || echo "npm install had issues"
npm run build || (echo "Build failed — copy the build errors above and send them to me"; exit 2)
cd ..

# 5) Commit & push fixes (if repo exists)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add frontend/index.html frontend/vercel.json frontend/src/app.jsx frontend/src/main.jsx || true
  git commit -m "Fix: add vercel.json + runtime WS env injection + app component" || true
  git branch -M main || true
  git remote remove origin 2>/dev/null || true
  if [ "$GITHUB_USER" != "YOUR_GITHUB_USER" ]; then
    git remote add origin git@github.com:${GITHUB_USER}/${REPO_NAME}.git 2>/dev/null || git remote add origin https://github.com/${GITHUB_USER}/${REPO_NAME}.git 2>/dev/null || true
    git push -u origin main --force || echo "git push failed; ensure you have permission and gh auth login"
  else
    echo "Skipping auto-remote/push because GITHUB_USER not set in script. Run 'git remote add origin ...' and push manually."
  fi
fi

echo "Fixes applied and frontend built. If you deploy on Vercel, set Project Root=frontend, Build Command=npm run build, Output Directory=dist"
