#!/usr/bin/env bash
# Playwright sandbox test: launches Chromium, Firefox, and WebKit headless
# inside Microsoft's official Playwright image, renders a page, asserts DOM.
# Stresses: user namespaces (Chromium sandbox), shared memory (/dev/shm),
# many syscalls per browser. WebKit in particular trips up gVisor.
set -euo pipefail

command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

cat > "$WORK/test.js" <<'EOF'
const { chromium, firefox, webkit } = require('playwright');
(async () => {
  const engines = [['chromium', chromium], ['firefox', firefox], ['webkit', webkit]];
  for (const [name, engine] of engines) {
    const browser = await engine.launch();
    const page = await browser.newPage();
    await page.setContent('<h1 id="t">sandbox-' + name + '</h1>');
    const text = await page.textContent('#t');
    await page.screenshot({ path: '/work/' + name + '.png' });
    await browser.close();
    if (text !== 'sandbox-' + name) {
      throw new Error(name + ' DOM mismatch: ' + text);
    }
    console.log(name + ': ok');
  }
})().catch(e => { console.error(e); process.exit(1); });
EOF

cat > "$WORK/package.json" <<'EOF'
{ "name": "pw-sandbox-test", "version": "1.0.0", "dependencies": { "playwright": "1.43.0" } }
EOF

# --ipc=host gives /dev/shm enough room for Chromium; --init reaps zombies.
docker run --rm \
  --ipc=host --init \
  -v "$WORK:/work" -w /work \
  mcr.microsoft.com/playwright:v1.43.0-jammy \
  sh -ec 'npm install --silent && node test.js'

# Verify screenshots actually got written and are non-empty
for b in chromium firefox webkit; do
  [ -s "$WORK/$b.png" ] || { echo "FAIL: $b screenshot missing/empty"; exit 1; }
done

echo "PASS: playwright (3/3 engines, screenshots written)"
