#!/usr/bin/env bash
# fix_deploy_issues.sh — إصلاح شائع لمشاكل 404 / Mixed Content / Output dir
set -e

PROJECT_DIR="${1:-mic-consent-starter}"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "المشروع '$PROJECT_DIR' غير موجود في المجلد الحالي."
  exit 1
fi

cd "$PROJECT_DIR"

# 1) Add vercel.json for SPA rewrites (helps 404 for client-side routing)
cat > frontend/vercel.json <<'JSON'
{
  "rewrites": [
    { "source": "/(.*)", "destination": "/index.html" }
  ]
}
JSON

# 2) Add runtime env injection script in index.html if not present (enables REACT_APP_WS_URL)
INDEX_FILE="frontend/index.html"
if ! grep -q "window.__ENV" "$INDEX_FILE"; then
  awk 'BEGIN{print ""} {print} END{print ""}' "$INDEX_FILE" > /tmp/idx.tmp
  mv /tmp/idx.tmp "$INDEX_FILE"
fi

# Ensure index.html contains window.__ENV injection (safe to overwrite small header)
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
      // Inject REACT_APP_WS_URL from hosting env: set it in Vercel/Netlify as REACT_APP_WS_URL
      (function(){
        try {
          var env = {};
          // For Vercel, you'll set REACT_APP_WS_URL as environment variable.
          if (typeof REACT_APP_WS_URL !== 'undefined') env.REACT_APP_WS_URL = REACT_APP_WS_URL;
          window.__ENV = env;
        } catch(e) { window.__ENV = {}; }
      })();
    </script>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
HTML

# 3) Ensure frontend build works locally
echo "Installing frontend deps and building..."
cd frontend
npm install --silent || true
BUILD_OK=true
npm run build || BUILD_OK=false

if [ "$BUILD_OK" = false ]; then
  echo "خطأ: فشل build للـ frontend. انسخ كامل أخطاء البناء أعلاه وأرسلها لي."
  exit 1
fi

echo "Frontend build OK. dist contents:"
ls -la dist | sed -n '1,200p'

# 4) Commit fixes (if git repo)
cd ..
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add frontend/vercel.json frontend/index.html
  git commit -m "Fix: add vercel.json rewrite and runtime env injection for WS URL" || true
  git push origin main || true
fi

echo "✅ إصلاحات جاهزة وتم بناء الواجهة محلياً. اعد نشر (Redeploy) على Vercel/Render."
echo "تذكير: في Vercel - Project Root = frontend ، Build Command = npm run build ، Output Directory = dist"
echo "ضع متغير البيئة REACT_APP_WS_URL = https://<your-backend-host> في إعدادات الاستضافة (Vercel/Render)."
