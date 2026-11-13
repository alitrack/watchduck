#!/usr/bin/env node
/**
 * watchduck showcase regression — P2-4.
 *
 * Modes:
 *   node scripts/e2e.mjs --check
 *       Static assertions on a clean checkout: required files exist, key
 *       strings present (esc_map / p_frame / ST_Intersects / ST_Rotate /
 *       m_blocked / the boot-state machine), expected HTML element ids in
 *       the demo pages, and a syntax check of this script itself.
 *       No browser, no network. Exit 0 = all pass, 1 = any failure.
 *
 *   node scripts/e2e.mjs --browser [--url http://host:port]
 *       Full Playwright E2E against escapement3d.html (served by a local
 *       static server unless --url points at an existing one):
 *         1. load until ready (<= 120 s; ~40 MB DuckDB-WASM from CDN first hit)
 *         2. Start -> beats > 0
 *         3. Pause -> one Step -> trace verdict chip consistent with the
 *            last real p_frame result (lastTrace.blocked)
 *         4. slider to -0.30 mm + rebuild -> v-map shows 1,723 blocked
 *         5. Reset -> v-map back to 1,438 blocked
 *         6. experiment card opens and closes
 *         7. zero uncaught page errors
 *       Exit 0 = all pass, 1 = a check failed, 2 = Playwright or its
 *       chromium binary is missing (install guidance printed).
 *
 *   node scripts/e2e.mjs --browser --ready-timeout-ms 180000
 *       Raise the ready-wait ceiling (slow first CDN download).
 */
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const MODE = args.includes('--browser') ? 'browser' : args.includes('--check') ? 'check' : null;

if (!MODE) {
  console.error('usage: node scripts/e2e.mjs --check | --browser [--url http://host:port] [--ready-timeout-ms N]');
  process.exit(2);
}

const failures = [];
const ok = (msg) => console.log(`[e2e] ok   ${msg}`);
const fail = (msg) => { failures.push(msg); console.log(`[e2e] FAIL ${msg}`); };

/* ------------------------------------------------------------------ */
/* --check: static assertions                                          */
/* ------------------------------------------------------------------ */

const FILE_STRINGS = {
  // file: strings that must each occur at least once
  'escapement3d.html': [
    'esc_map', 'p_frame', 'ST_Intersects', 'ST_Rotate',
    'PREPARE p_frame', '__wdBootState', '__wd3d', 'N_STALL',
  ],
  'index2d.html': ['esc_map', 'ST_Intersects'],
  'index34.html': ['m_blocked'],
  '04_take_apart.sql': ['m_blocked', 'ST_Intersects'],
};

const FILE_IDS = {
  // file: element ids that must each appear in the HTML
  'escapement3d.html': [
    'v-beats', 'v-map', 'exp-slider', 'exp-details', 'exp-summary', 'exp-card',
    'exp-baseline', 'exp-experiment', 'exp-reset', 'exp-fault',
    'b-run', 'b-step', 'b-reset', 'b-copy-sql', 't-verdict', 'trace-card',
  ],
  'index.html': [],
};

const HUB_CTAS = ['Run Live SQL Simulation', 'Break the Watch', 'Take the story', 'View the SQL'];

const REQUIRED_FILES = [
  'index.html', 'escapement3d.html', 'index2d.html', 'index34.html',
  '04_take_apart.sql', 'movement_snapshot.json', 'scripts/geometry.py',
  'README.md', 'README_cn.md',
];

function runCheck() {
  console.log(`[e2e] --check: static assertions (root: ${ROOT})`);
  for (const f of REQUIRED_FILES) {
    const p = path.join(ROOT, f);
    if (fs.existsSync(p) && fs.statSync(p).size > 0) ok(`file: ${f}`);
    else fail(`file: ${f} missing or empty`);
  }
  for (const [f, strings] of Object.entries(FILE_STRINGS)) {
    let src = '';
    try { src = fs.readFileSync(path.join(ROOT, f), 'utf8'); } catch { fail(`read: ${f}`); continue; }
    for (const s of strings) (src.includes(s) ? ok : fail)(`${f} contains "${s}"`);
  }
  for (const [f, ids] of Object.entries(FILE_IDS)) {
    let src = '';
    try { src = fs.readFileSync(path.join(ROOT, f), 'utf8'); } catch { continue; }
    for (const id of ids) (src.includes(`id="${id}"`) ? ok : fail)(`${f} has id="${id}"`);
  }
  {
    const hub = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
    for (const cta of HUB_CTAS) (hub.includes(cta) ? ok : fail)(`index.html has CTA "${cta}"`);
  }
  {
    // this script must be syntactically valid node
    const r = spawnSync(process.execPath, ['--check', path.join(ROOT, 'scripts/e2e.mjs')], { stdio: 'pipe' });
    (r.status === 0 ? ok : fail)(`node --check scripts/e2e.mjs`);
    if (r.status !== 0) console.log(String(r.stderr || '').trim());
  }
  return finish('check');
}

/* ------------------------------------------------------------------ */
/* --browser: Playwright E2E                                           */
/* ------------------------------------------------------------------ */

function serveRoot() {
  const server = http.createServer((req, res) => {
    let u = decodeURIComponent((req.url || '/').split('?')[0]);
    if (u === '/') u = '/index.html';
    const p = path.join(ROOT, path.normalize(u).replace(/^(\.\.[/\\])+/, ''));
    if (!p.startsWith(ROOT) || !fs.existsSync(p) || !fs.statSync(p).isFile()) {
      res.writeHead(404); res.end('not found'); return;
    }
    const ext = path.extname(p).toLowerCase();
    const type = ext === '.html' ? 'text/html'
      : ext === '.js' || ext === '.mjs' ? 'text/javascript'
      : ext === '.json' ? 'application/json'
      : ext === '.css' ? 'text/css'
      : 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': type });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

const INSTALL_GUIDE = [
  'Playwright is required for --browser mode but was not loaded / its chromium is missing.',
  'Install (in the repo root):',
  '  npm install',
  '  npx playwright install chromium',
  'or run --check, which needs no browser at all.',
];

async function runBrowser() {
  let pw;
  try { pw = await import('playwright'); }
  catch (e) { console.log(`[e2e] --browser: cannot require("playwright"): ${e.message}`); console.log(INSTALL_GUIDE.join('\n')); return 2; }
  const chromium = pw.chromium;
  let exe;
  try { exe = chromium.executablePath(); } catch { exe = ''; }
  if (!exe || !fs.existsSync(exe)) {
    console.log(`[e2e] --browser: chromium binary not found (looked for: ${exe || 'unknown'}).`);
    console.log(INSTALL_GUIDE.join('\n'));
    return 2;
  }

  const urlArgIdx = args.indexOf('--url');
  const base = urlArgIdx >= 0 ? args[urlArgIdx + 1] : null;
  const rtIdx = args.indexOf('--ready-timeout-ms');
  const readyTimeout = rtIdx >= 0 ? Number(args[rtIdx + 1]) || 120000 : 120000;
  const server = base ? null : await serveRoot();
  const origin = base || `http://127.0.0.1:${server.address().port}`;
  console.log(`[e2e] --browser: chromium ${path.basename(exe)}`);
  console.log(`[e2e] --browser: target ${origin}/escapement3d.html (ready timeout ${readyTimeout} ms)`);

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(String(e)));

  // small helper: poll a page function until it returns a value that passes
  // `expect`. `arg` (if given) is passed to the evaluated function, so the
  // condition can be deterministic (e.g. "trace.step > the step I saw before
  // I clicked Step" — the page's manual-step handler redraws the verdict chip
  // in the same continuation that records the new trace, so once trace.step
  // advanced, chip and lastTrace are the very same substep).
  const poll = async (what, fn, timeoutMs, expect = (v) => v, arg) => {
    const t0 = Date.now();
    for (;;) {
      let v = null;
      try { v = await page.evaluate(fn, arg); } catch { /* page mid-navigation */ }
      // `v !== null` (not truthy): a legitimate result can be false / 0 / ''
      if (v !== null && expect(v)) return v;
      if (Date.now() - t0 > timeoutMs) throw new Error(`timed out after ${timeoutMs} ms waiting for: ${what}`);
      await new Promise((r) => setTimeout(r, 250));
    }
  };
  const text = (sel) => page.$eval(sel, (el) => el.textContent).catch(() => '');
  const step = (name, fn) => fn().then(
    () => ok(`step: ${name}`),
    (e) => fail(`step: ${name} — ${e.message}`),
  );

  try {
    await page.goto(`${origin}/escapement3d.html`, { waitUntil: 'domcontentloaded', timeout: 60000 });

    // 1. engine reaches ready (wasm download included; CDN-cached after first hit)
    await step('load until ready', async () => {
      const st = await poll('boot state ready', () => window.__wdBootState, readyTimeout,
        (s) => s === 'ready');
      if (st !== 'ready') throw new Error(`boot state stuck at "${st}"`);
    });

    // 2. Start -> beats > 0
    await step('Start -> beats > 0', async () => {
      await page.click('#b-run');
      await poll('beats > 0', () => window.__wd3d().beats, 30000, (b) => b > 0);
    });

    // 3. Pause -> one manual Step. b-step redraws the verdict chip in the
    //    same continuation that records the new trace, so once trace.step
    //    has advanced past the step I observed before the click, the chip
    //    and lastTrace are guaranteed to be the very same substep — no race.
    //    The chip must then agree with the real p_frame result.
    await step('Pause -> trace chip == lastTrace.blocked', async () => {
      await page.click('#b-run'); // Pause
      const stepBefore = await page.evaluate(() => {
        const t = window.__wd3d().trace; return t ? t.step : 0;
      });
      await page.click('#b-step');
      const tr = await poll('manual substep to complete', (s0) => {
        const t = window.__wd3d().trace;
        return (t && t.step > s0) ? t : null;
      }, 15000, (t) => t, stepBefore);
      const chip = await text('#t-verdict');
      if (!chip.includes(tr.blocked ? 'blocked = 1' : 'blocked = 0')) {
        throw new Error(`chip "${chip}" disagrees with lastTrace.blocked=${tr.blocked}`);
      }
      if (!chip.includes(tr.blocked ? '▲' : '○')) {
        throw new Error(`chip "${chip}" lacks the ${tr.blocked ? 'collision' : 'free'} mark`);
      }
    });

    // 4. slider to -0.30 mm: the 'change' handler rebuilds (no probe)
    await step('slider -0.30 rebuild -> v-map 1,723 blocked', async () => {
      await page.$eval('#exp-slider', (el) => {
        el.value = '-0.30';
        el.dispatchEvent(new Event('change', { bubbles: true }));
      });
      await poll('rebuild finished at -0.30', () => window.__wd3d().rebuilding, 90000,
        (b) => b === false);
      const entryOff = await page.evaluate(() => window.__wd3d().entryOff);
      if (entryOff !== -0.3) throw new Error(`entryOff is ${entryOff}, expected -0.3`);
      const vm = await text('#v-map');
      if (!/1[,. ]?723/.test(vm)) throw new Error(`v-map "${vm}" does not show 1,723 blocked`);
    });

    // 5. Reset -> baseline map (1,438 blocked)
    await step('Reset -> v-map 1,438 blocked', async () => {
      await page.click('#exp-reset');
      await poll('rebuild finished at 0.00', () => window.__wd3d().rebuilding, 90000,
        (b) => b === false);
      const entryOff = await page.evaluate(() => window.__wd3d().entryOff);
      if (entryOff !== 0) throw new Error(`entryOff is ${entryOff}, expected 0`);
      const vm = await text('#v-map');
      if (!/1[,. ]?438/.test(vm)) throw new Error(`v-map "${vm}" does not show 1,438 blocked`);
    });

    // 6. experiment card toggles open/closed
    await step('experiment card open/close', async () => {
      const isOpen = () => page.$eval('#exp-details', (el) => el.hasAttribute('open'));
      const before = await isOpen();
      await page.click('#exp-summary');
      const after = await isOpen();
      if (after === before) throw new Error('clicking the summary did not toggle the card');
      await page.click('#exp-summary');
      if ((await isOpen()) !== before) throw new Error('card did not return to its original state');
    });

    // 7. no uncaught page errors anywhere in the run
    await step('zero pageerror', async () => {
      if (pageErrors.length) throw new Error(`pageerror: ${pageErrors.join(' | ').slice(0, 400)}`);
    });
  } catch (e) {
    fail(`run aborted — ${e.message}`);
    if (pageErrors.length) console.log('[e2e] pageerror: ' + pageErrors.join(' | ').slice(0, 600));
  } finally {
    await browser.close().catch(() => {});
    if (server) await new Promise((r) => server.close(r));
  }
  return finish('browser');
}

/* ------------------------------------------------------------------ */

function finish(mode) {
  const total = failures.length === 0 ? 'PASS' : `FAIL (${failures.length})`;
  console.log(`[e2e] --${mode}: ${total}`);
  return failures.length === 0 ? 0 : 1;
}

const code = MODE === 'check' ? runCheck() : await runBrowser();
process.exit(code);
