// 3d-verify-worker.mjs — genuine volumetric 3D cross-verification in a Web Worker.
//
// Role (per the 2026-11-14 load-bearing decision for task #2026110903): the page's
// physics is the 2D DuckDB `ST_Intersects` grid (one SQL query per sub-step, µs-level,
// drives the display). This Worker runs an INDEPENDENT 3D engine — SFCGAL 2.3.0 in
// wasm (CGAL, pure-exact Gmpq kernel) — on the SAME escapement geometry, computing a
// real volumetric intersection of the rotated wheel-tooth prism × each pallet-stone
// prism every tick. The two engines, two representations, one physics; they must agree.
//
// Why a Worker (not the main thread): a real 3D boolean is ~14 ms (free) to ~92 ms
// (blocked, deep-mesh tail) — 4.3× under the 12 Hz tick budget on average, but a
// 209 ms tail spike would jank the render loop if it ran on the main thread. In a
// Worker the spike is absorbed (transient backlog ≤ ~1 tick, bounded) and the verdict
// comes out one frame late — a verification signal, not the driver.
//
// The page's 2D grid is wheel 0.25° × fork 0.5°. The Worker pre-builds the 195
// solids the grid actually spans (97 tooth + 49 entry + 49 exit) ONCE, then every
// tick is two pre-built-solid intersections + volume — no per-tick geometry parse.
//
// Geometry is the page's verbatim (escapement3d.html L134-140): the same constants,
// the same rotate-about-origin + translate-PIVOT transform, extruded to a z∈[-0.5,0.5]
// prism (the mechanism is coplanar, so a 3D clash ⟺ a 2D profile overlap).
//
// Bootstrap model: the wasm module is loaded at WORKER STARTUP (top-level), not on the
// first tick. The page only starts feeding ticks after it has received 'ready', so
// gating the module load on a message would deadlock (message waits for ready, ready
// waits for message). Ticks that arrive before the module is ready are queued and
// drained the moment 'ready' posts — bounded to at most one frame.
let run = null;                 // set once the module + 195 solids are built
let tickQueue = [];
function drainTickQueue() { for (let i = 0; i < tickQueue.length; i++) run(tickQueue[i]); tickQueue = []; }
self.onmessage = (e) => {
  const d = e.data;
  if (d && d.type === 'ping') { postMessage({ type: 'pong' }); return; }
  if (!run) { if (d && d.type === 'tick') tickQueue.push(d); return; }   // not ready yet — queue
  run(d);
};
try {
    const M = (await import('./sfcgal3d_32fix.wasm.js')).default;
    const m = await M();
    const c = (n, t, ty, a) => m.ccall(n, t, ty, a);

    // ---- page geometry, verbatim (escapement3d.html L134-140) ----
    const R = 10.0;
    const TOOTH = [[-0.9, -0.55], [0.75, -0.35], [0.45, 0.85], [-0.9, 0.55]];
    const PIVOT = [0.0, 13.906841355503715];
    const SL = 4.172168276032077, SW = 0.9435838419903526;
    const ENTRY = [-3.698835219030193, -1.92158763948672];
    const EXIT = [3.7889791082288786, -2.3478770420636748];

    const toothPts = (wd) => {
      const base = TOOTH.map(([x, y]) => [-y, R + x]);
      const a = wd * Math.PI / 180, cs = Math.cos(a), sn = Math.sin(a);
      return base.map(([x, y]) => [x * cs - y * sn, x * sn + y * cs]);
    };
    const stonePts = (which, fd) => {
      const [lx, ly] = which === 'entry' ? ENTRY : EXIT;
      const hw = SW / 2, hl = SL / 2;
      const local = [[lx - hw, ly - hl], [lx + hw, ly - hl], [lx + hw, ly + hl], [lx - hw, ly + hl]];
      const a = fd * Math.PI / 180, cs = Math.cos(a), sn = Math.sin(a);
      return local.map(([x, y]) => [x * cs - y * sn + PIVOT[0], x * sn + y * cs + PIVOT[1]]);
    };
    // FULL precision (String(v)) — toFixed(4) at coordinate magnitude ~10-14 breaks
    // the polyhedral surface's watertightness and make_solid rejects it (the F4 bug).
    const FULL = v => String(v);
    const Z0 = -0.5, Z1 = 0.5;
    const prismWkt = (pts) => {
      const n = pts.length; let s = 'POLYHEDRALSURFACE Z ('; let first = true;
      const ring = (z, rev) => {
        if (!first) s += ', '; first = false; s += '((';
        for (let i = 0; i <= n; i++) { const k = rev ? ((n - i) % n) : (i % n); if (i) s += ', '; s += FULL(pts[k][0]) + ' ' + FULL(pts[k][1]) + ' ' + z; }
        s += '))';
      };
      ring(Z0, true); ring(Z1, false);
      for (let i = 0; i < n; i++) { const a = pts[i], b = pts[(i + 1) % n]; if (!first) s += ', '; first = false;
        s += '((' + FULL(a[0]) + ' ' + FULL(a[1]) + ' ' + Z0 + ', ' + FULL(b[0]) + ' ' + FULL(b[1]) + ' ' + Z0 + ', ' +
             FULL(b[0]) + ' ' + FULL(b[1]) + ' ' + Z1 + ', ' + FULL(a[0]) + ' ' + FULL(a[1]) + ' ' + Z1 + ', ' +
             FULL(a[0]) + ' ' + FULL(a[1]) + ' ' + Z0 + ' ))'; }
      s += ')'; return s;
    };
    // read_wkt takes a STRING arg (the C side strlen's it) — pass the WKT string, not a heap pointer.
    const buildSolid = (wkt) => {
      const h = c('sfcgal3d_read_wkt', 'number', ['string'], [wkt]);
      if (!h) return 0;
      const sol = c('sfcgal3d_make_solid', 'number', ['number'], [h]);
      c('sfcgal3d_delete', 'number', ['number'], [h]);   // free surface, keep the solid
      return sol;
    };
    const del = h => { if (h) c('sfcgal3d_delete', 'number', ['number'], [h]); };

    c('sfcgal3d_init', 'number', [], []);
    const W_STEP = 0.25, W_MAX = 24, F_STEP = 0.5, F_MAX = 12;
    const teeth = new Map(), entries = new Map(), exits = new Map();
    let buildFail = 0;
    for (let i = 0; i <= W_MAX / W_STEP; i++) { const w = i * W_STEP; const s = buildSolid(prismWkt(toothPts(w))); if (!s) buildFail++; teeth.set(w, s); }
    for (let j = 0; j <= 2 * F_MAX / F_STEP; j++) { const f = j * F_STEP - F_MAX;
      const se = buildSolid(prismWkt(stonePts('entry', f))); if (!se) buildFail++; entries.set(f, se);
      const sx = buildSolid(prismWkt(stonePts('exit', f)));  if (!sx) buildFail++; exits.set(f, sx); }
    const nSolids = teeth.size + entries.size + exits.size;
    let checked = 0, diverged = 0;
    run = (q) => {
      if (!q || q.type !== 'tick') return;
      // quantize to the page's own grid (wheel 0.25°, fork 0.5°) so the 3D solids
      // line up with the 2D grid — an off-grid lookup misses the pre-built set.
      const wq = Math.round(((q.wheel % 24) + 24) % 24 * 4) / 4;
      const fq = Math.round(q.fork / 0.5) * 0.5;
      const sT = teeth.get(wq), sE = entries.get(fq), sX = exits.get(fq);
      if (!sT || !sE || !sX) { postMessage({ type: 'verdict', noSolid: true, wheel: q.wheel, fork: q.fork, seq: q.seq }); return; }
      const t0 = performance.now();
      let vE = 0, vX = 0;
      { const u = c('sfcgal3d_intersection_3d', 'number', ['number', 'number'], [sT, sE]); if (u) { vE = c('sfcgal3d_volume', 'number', ['number'], [u]); del(u); } }
      { const u = c('sfcgal3d_intersection_3d', 'number', ['number', 'number'], [sT, sX]); if (u) { vX = c('sfcgal3d_volume', 'number', ['number'], [u]); del(u); } }
      const ms = performance.now() - t0;
      const clash = (vE > 1e-9) || (vX > 1e-9);
      checked++;
      // Divergence CLASS, not just a boolean — a verification signal that paints one
      // color for "hidden interference" and "touching without volume" is useless:
      //   real     — 2D clear but 3D clash (SQL grid missed interference), or 2D
      //              blocked but 3D shows NO contact at all (vol exactly 0): a lock
      //              that does not physically exist. Both must paint red.
      //   boundary — 2D blocked, 3D vol ≤ 1e-9 but > 0: the tooth and stone are
      //              touching (ST_Intersects counts a touch), volume below threshold.
      //              The documented single-cell class from the 4753-cell offline
      //              cross-check (6.9e-10). Expected, not a fault → amber.
      let divKind = 'none';
      if (typeof q.blocked === 'boolean' && clash !== q.blocked) {
        diverged++;
        divKind = (!q.blocked) ? 'real' : ((vE > 0 || vX > 0) ? 'boundary' : 'real');
      }
      postMessage({ type: 'verdict', clash, vE, vX, ms, checked, diverged, divKind, divergedNow: divKind !== 'none', wheel: q.wheel, fork: q.fork, seq: q.seq });
    };
    postMessage({ type: 'ready', sfcgal: c('sfcgal3d_version', 'string', [], []), solids: nSolids, buildFail });
    drainTickQueue();
  } catch (err) {
    postMessage({ type: 'error', msg: String(err && err.message || err) });
  }
