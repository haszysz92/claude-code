#!/usr/bin/env bash
# Install (when needed), build (when needed), and serve the project in the
# foreground. All source and generated output stays inside PROJECT_DIR; only
# worker metadata is written to OPENCODE_WEB_DIR.
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-3000}"
WEB_DIR="${OPENCODE_WEB_DIR:-/home/runner/work/_temp/omgithub-web}"
DIST_DIR="$PROJECT_DIR/dist"

timed() { /usr/bin/time -p "$@"; }
log() { printf '[start] %s\n' "$*"; }

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
  echo "PORT must be a number, got: $PORT" >&2
  exit 1
fi

cd "$PROJECT_DIR"
timed mkdir -p "$WEB_DIR" "$DIST_DIR"

install_and_build() {
  [[ -f package.json ]] || return 0

  log "Installing dependencies"
  if [[ -f package-lock.json ]]; then
    timed npm ci --no-audit --no-fund
  else
    timed npm install --no-audit --no-fund
  fi

  if node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)"; then
    log "Running package build script"
    timed npm run build
  elif [[ -f node_modules/vite/bin/vite.js ]]; then
    log "Running Vite build"
    timed node node_modules/vite/bin/vite.js build
  fi
}

select_output() {
  local candidate
  for candidate in dist build out .output/public public; do
    if [[ -f "$PROJECT_DIR/$candidate/index.html" ]]; then
      printf '%s\n' "$PROJECT_DIR/$candidate"
      return 0
    fi
  done
  if [[ -f "$PROJECT_DIR/index.html" ]]; then
    printf '%s\n' "$PROJECT_DIR"
    return 0
  fi
  return 1
}

generate_landing_page() {
  log "No static entry point found; generating a landing page from README.md"
  timed node --input-type=module - "$PROJECT_DIR" "$DIST_DIR" <<'NODE'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [project, dist] = process.argv.slice(2)
let source = ''
try {
  source = readFileSync(join(project, 'README.md'), 'utf8')
} catch {
  source = '# claude-code\n\nStatic project preview.'
}
source = source.replace(/<!--[\s\S]*?-->/g, '')

const escape = value => value
  .replace(/&/g, '&amp;')
  .replace(/</g, '&lt;')
  .replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;')

const inline = value => {
  let out = escape(value)
  out = out.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, '<img alt="$1" src="$2" loading="lazy">')
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>')
  out = out.replace(/`([^`]+)`/g, '<code>$1</code>')
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
  return out
}

const body = []
let inList = false
for (const raw of source.split(/\r?\n/)) {
  const line = raw.replace(/\s+$/, '')
  if (/^\s*[-*]\s+/.test(line)) {
    if (!inList) { body.push('<ul>'); inList = true }
    body.push(`<li>${inline(line.replace(/^\s*[-*]\s+/, ''))}</li>`)
    continue
  }
  if (inList) { body.push('</ul>'); inList = false }
  if (line.trim() === '') continue
  const heading = line.match(/^(#{1,6})\s+(.*)$/)
  if (heading) {
    const level = heading[1].length
    body.push(`<h${level}>${inline(heading[2])}</h${level}>`)
    continue
  }
  body.push(`<p>${inline(line)}</p>`)
}
if (inList) body.push('</ul>')
if (body.length === 0) body.push('<h1>claude-code</h1><p>Static project preview.</p>')

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>claude-code</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; line-height: 1.65; color: #1f2933; background: radial-gradient(circle at 15% 0%, #dbeafe 0, transparent 45%), radial-gradient(circle at 100% 10%, #fce7f3 0, transparent 40%), #f8fafc; }
  main { width: min(860px, calc(100% - 2rem)); margin: 0 auto; padding: 3.5rem 0 4rem; }
  h1, h2, h3 { line-height: 1.2; letter-spacing: -0.02em; }
  h1 { font-size: clamp(2rem, 6vw, 3.25rem); margin: 0 0 1rem; }
  h2 { margin: 2.25rem 0 1rem; font-size: clamp(1.35rem, 3vw, 1.9rem); }
  h3 { margin: 1.75rem 0 .75rem; }
  p { margin: .75rem 0; }
  ul { padding-left: 1.25rem; }
  li { margin: .45rem 0; }
  a { color: #1d4ed8; text-underline-offset: 3px; }
  a:hover { color: #1e40af; }
  img { max-height: 28px; vertical-align: middle; margin-right: .4rem; }
  code { background: rgba(15, 23, 42, .08); padding: .15rem .35rem; border-radius: .35rem; font-size: .92em; }
  strong { font-weight: 650; }
  @media (prefers-color-scheme: dark) {
    body { color: #e2e8f0; background: radial-gradient(circle at 15% 0%, #1e3a8a 0, transparent 45%), radial-gradient(circle at 100% 10%, #831843 0, transparent 40%), #0f172a; }
    a { color: #93c5fd; }
    a:hover { color: #bfdbfe; }
    code { background: rgba(226, 232, 240, .15); }
  }
</style>
</head>
<body>
<main>
${body.join('\n')}
</main>
</body>
</html>
`
mkdirSync(dist, { recursive: true })
writeFileSync(join(dist, 'index.html'), html)
NODE
}

install_and_build

if ! SERVE_DIR="$(select_output)"; then
  generate_landing_page
  SERVE_DIR="$DIST_DIR"
fi

SERVE_DIR="$(cd -- "$SERVE_DIR" && pwd)"
case "$SERVE_DIR" in
  "$PROJECT_DIR"|"$PROJECT_DIR"/*) ;;
  *) echo "Static output must stay inside $PROJECT_DIR, got: $SERVE_DIR" >&2; exit 1 ;;
esac

log "Publishing deployment metadata"
timed node --input-type=module - "$PROJECT_DIR" "$SERVE_DIR" "$WEB_DIR" <<'NODE'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const [project, directory, web] = process.argv.slice(2)
mkdirSync(web, { recursive: true })
writeFileSync(
  join(web, 'deployment-output.json'),
  JSON.stringify({ project: resolve(project), directory: resolve(directory) })
)
NODE

log "Serving $SERVE_DIR on 0.0.0.0:$PORT"
timed node --input-type=module - "$SERVE_DIR" "$PORT" <<'NODE'
import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import { extname, resolve, sep } from 'node:path'

const [root, port] = process.argv.slice(2)
const base = resolve(root)
const mime = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.wasm': 'application/wasm',
  '.glb': 'model/gltf-binary',
  '.gltf': 'model/gltf+json',
  '.bin': 'application/octet-stream',
  '.mp3': 'audio/mpeg',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm'
}

const server = createServer(async (request, response) => {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, { Allow: 'GET, HEAD' })
    response.end('Method not allowed')
    return
  }
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname)
    if (pathname.includes('\0')) throw new Error('Invalid path')
    let target = resolve(base, '.' + pathname)
    if (target !== base && !target.startsWith(base + sep)) {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
      response.end('Not found')
      return
    }
    let info = await stat(target).catch(() => null)
    if (info?.isDirectory()) {
      target = resolve(target, 'index.html')
      info = await stat(target).catch(() => null)
    }
    if (!info && !extname(pathname)) {
      target = resolve(base, 'index.html')
      info = await stat(target).catch(() => null)
    }
    if (!info) {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
      response.end('Not found')
      return
    }
    const data = await readFile(target)
    response.writeHead(200, {
      'Content-Type': mime[extname(target).toLowerCase()] || 'application/octet-stream',
      'Content-Length': data.length,
      'Cache-Control': 'no-cache',
      'X-Content-Type-Options': 'nosniff'
    })
    response.end(request.method === 'HEAD' ? undefined : data)
  } catch (error) {
    response.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' })
    response.end('Bad request')
  }
})

server.listen(Number(port), '0.0.0.0', () => {
  console.log(`Static server listening on http://0.0.0.0:${port} (root: ${base})`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 5000).unref()
  })
}
NODE
