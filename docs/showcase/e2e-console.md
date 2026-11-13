# Browser-console E2E for the 3D escapement

A paste-able verification script for `escapement3d.html`. It asserts the same
things as `node scripts/e2e.mjs --browser`, for humans who verify in a real
browser (e.g. the coordinator's screenshot pass) without running Node.

**How to run**

1. Serve the repo: `python3 -m http.server 8000` (the page must be on `http`,
   not `file://` — the wasm engine loads from a CDN and the page uses
   module scripts).
2. Open `http://localhost:8000/escapement3d.html` in Chromium and wait for the
   status line to read `ready` (first load downloads ~40 MB from the CDN).
3. Paste the block below into DevTools → Console → Enter.

The script drives the real UI (it clicks the same buttons a user would) and
reads only real page state (`window.__wd3d()`, `window.__wdBootState`, the
live DOM). It prints one line per check and a final `CONSOLE E2E: PASS/FAIL`.
It never injects fake verdicts — if the SQL pipeline misbehaves, a check
fails and says so.

**What it checks (same order as `--browser`)**

1. engine reached `ready` (≤ 120 s)
2. `Start` → beats counter > 0
3. `Pause` → one `Step` → the "last verdict" chip agrees with the last real
   `p_frame` result (`blocked` value and ▲/○ mark)
4. slider to −0.30 mm (change event) → rebuild → collision-map counter shows
   **1,723 blocked** (of 4,753 states)
5. `Reset` → back to the 0.00 mm baseline → **1,438 blocked**
6. the "Break the Watch" card opens and closes
7. no uncaught page errors since the script was pasted

```js
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const $ = (s) => document.querySelector(s);
  const snap = () => window.__wd3d();
  const results = [];
  const check = (name, cond, detail = '') => {
    results.push({ name, pass: !!cond });
    console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
  };
  const poll = async (what, fn, timeoutMs) => {
    const t0 = Date.now();
    for (;;) {
      const v = await fn().catch(() => null);
      if (v !== null && v !== undefined) return v;
      if (Date.now() - t0 > timeoutMs) throw new Error(`timeout: ${what}`);
      await sleep(250);
    }
  };

  window.__wdErrors = [];
  window.addEventListener('error', (e) => window.__wdErrors.push(String(e.message)));
  window.addEventListener('unhandledrejection', (e) => window.__wdErrors.push('promise: ' + String(e.reason)));

  // 1. ready
  if (window.__wdBootState !== 'ready') {
    try {
      await poll('engine ready', async () =>
        window.__wdBootState === 'ready' ? 1 : null, 120000);
    } catch (e) {
      check('engine ready', false, `stuck at "${window.__wdBootState}" (${e.message})`);
      return console.log('CONSOLE E2E: FAIL');
    }
  }
  check('engine ready', true, window.__wdBootState);

  // 2. Start -> beats > 0
  $('#b-run').click();
  await poll('beats > 0', async () => (snap().beats > 0 ? snap().beats : null), 30000);
  check('Start -> beats > 0', snap().beats > 0, `beats=${snap().beats}`);

  // 3. Pause -> one Step -> chip consistent with the real p_frame verdict.
  //    The page redraws the chip in the same continuation that records the
  //    new trace, so once trace.step advanced the chip is the same substep.
  $('#b-run').click(); // Pause
  const stepBefore = snap().trace ? snap().trace.step : 0;
  $('#b-step').click();
  await poll('manual substep', async () =>
    (snap().trace && snap().trace.step > stepBefore) ? 1 : null, 15000);
  const tr = snap().trace;
  const chip = $('#t-verdict').textContent;
  check('Pause -> trace chip == lastTrace.blocked',
    tr && chip.includes(tr.blocked ? 'blocked = 1' : 'blocked = 0') &&
    chip.includes(tr.blocked ? '▲' : '○'),
    `chip="${chip}" blocked=${tr && tr.blocked}`);

  // 4. slider to -0.30 mm (change event) -> rebuild -> 1,723 blocked
  const slider = $('#exp-slider');
  slider.value = '-0.30';
  slider.dispatchEvent(new Event('change', { bubbles: true }));
  await poll('rebuild at -0.30', async () =>
    (snap().rebuilding === false && snap().entryOff === -0.3) ? 1 : null, 90000);
  const vm1 = $('#v-map').textContent;
  check('slider -0.30 -> v-map 1,723 blocked', /1[,. ]?723/.test(vm1), vm1);

  // 5. Reset -> 1,438 blocked
  $('#exp-reset').click();
  await poll('reset to 0.00', async () =>
    (snap().rebuilding === false && snap().entryOff === 0) ? 1 : null, 90000);
  const vm0 = $('#v-map').textContent;
  check('Reset -> v-map 1,438 blocked', /1[,. ]?438/.test(vm0), vm0);

  // 6. experiment card toggles
  const d = $('#exp-details');
  const before = d.hasAttribute('open');
  $('#exp-summary').click();
  const flipped = d.hasAttribute('open') !== before;
  $('#exp-summary').click();
  check('experiment card open/close', flipped && d.hasAttribute('open') === before);

  // 7. no uncaught errors since paste
  check('no uncaught page errors', window.__wdErrors.length === 0,
    window.__wdErrors.join(' | ').slice(0, 200));

  const failed = results.filter((r) => !r.pass).length;
  console.log(failed === 0
    ? `CONSOLE E2E: PASS (${results.length}/${results.length} checks)`
    : `CONSOLE E2E: FAIL (${failed} of ${results.length} checks)`);
})();
```

**Notes**

- Check 3 waits for the manual step to be *recorded* (`trace.step` advanced)
  before reading the chip, so there is no race between the SQL result and the
  chip it renders.
- Checks 4–5 exercise the real rebuild chain: new entry-stone WKT →
  `CREATE OR REPLACE TABLE esc_map` (97 × 49 grid) → re-`PREPARE p_frame` →
  motion reset. The counts 1,723 / 1,438 are measured properties of those
  rebuilt maps, not expectations painted on by the script.
- The error listener only catches errors thrown *after* the paste; a fully
  clean page should report none.
- If you are on a slow link, give check 1 more time by raising `120000` (ms)
  in the script, or open the page once first so the CDN download is cached.
