# WatchDuck showcase — M0 baseline

Recorded on the `master` branch before any showcase work. Every number below is from a
local run or from reading the code; nothing is estimated unless marked "estimate".

## 1. Git state (before changes)

- Repo: `/home/lhy/watchduck` (github.com/alitrack/watchduck), branch `master`
- HEAD: `ffab8d8` — "index34 + escapement3d body text to English … verified 8-round GOLDEN MATCH, 0 errors"
- `git status`: clean work tree, in sync with `origin/master`
- No uncommitted modifications existed; none were made before M0.
- Change branch for this campaign: `showcase-p0` (created off `ffab8d8`).

Recent history (context):

```
ffab8d8 index34 + escapement3d body text to English (site fully EN; verified 8-round GOLDEN MATCH, 0 errors)
b807cb5 hub + nav bars to English (site is EN-first; README_cn already covers the Chinese intro)
b195e88 hub page: index.html is now a nav landing linking the three demos; old default
        escapement 3D renamed to escapement3d.html; dropped orphan index3d.html;
        every page gets a top nav bar (hub/34-part/3D/2D)
```

## 2. Geometry acceptance script — real output

Command: `python3 scripts/geometry.py` (run locally on this machine, verbatim output):

```
LOCK   blocked@fork0      : 0.78  (want >= 0.35)
RELEASE free run @ -10deg : 11.2 deg (want ~= 10.8)
RELEASE free run @ +10deg : 10.8 deg (want ~= 10.8)
DEAD ZONES                : 0.000 (want 0)
ACCEPTANCE: PASS
```

What the four criteria mean (from the script's docstring — the polygons were found by
random search against purely geometric criteria, nothing encodes "12° per beat"):

1. **LOCK** — fork centered (0°): the escape wheel is blocked for 0.78 of its phase
   window (≥ 0.35 required). The wheel rests, held by a stone.
2. **RELEASE** — fork at −10° / +10°: the longest unblocked wheel travel is
   11.2° / 10.8°, ≈ half a tooth pitch (0.45 × 24° = 10.8° target). This is the
   free-run *length*, not the per-beat advance.
3. **NO DEAD ZONES** — for every wheel phase, at least one fork angle frees the wheel:
   measured 0.000 (≤ 0.02 required).
4. The "half a tooth pitch per beat" advance then falls out of these shapes at runtime
   inside DuckDB, when the solver walks the collision map.

## 3. Static site — page reachability

`cd /home/lhy/watchduck && python3 -m http.server 8000`, then `curl` per page
(server was started, probed, and killed again; results below):

| path | HTTP | bytes |
|---|---|---|
| index.html | 200 | 5006 |
| escapement3d.html | 200 | 61950 |
| index2d.html | 200 | 19825 |
| index34.html | 200 | 39596 |
| movement_snapshot.json | 200 | 888299 |
| 04_take_apart.sql | 200 | 11687 |

## 4. Current state of the four pages (from code reading — no speculation)

### index.html — hub (static, 5.0 KB)

- Pure nav landing page, no JavaScript at all: title/subtitle explaining the approach
  (parts are polygons in DuckDB, collisions = `ST_Intersects` pairwise verdicts,
  ticking = a recursive SQL solver, disassembly = `m_blocked()` asking "who can move
  right now?"), three demo cards (34-part / 3D / 2D), a top nav bar linking all four
  pages, footer with upstream credit (sqlartist/watchmaker-sql).
- Does not load DuckDB-WASM, Three.js, or any CDN script. Fast by construction.

### escapement3d.html — 3D Swiss lever escapement (62 KB)

- Three.js r160 (jsDelivr CDN) scene: movement plate, 15-tooth escape wheel, pallet
  fork with ruby stones, balance + hairspring, dial with real-time hands.
- DuckDB-WASM `1.33.1-dev57.0` from jsDelivr, run in a worker. Boot chain:
  `selectBundle → createWorker → instantiate → connect → LOAD spatial`
  (falls back to `INSTALL spatial; LOAD spatial`).
- Collision map built in SQL: `CREATE OR REPLACE TABLE esc_map AS …` over a
  **97 × 49** wheel-phase × fork-angle grid (`W_MAX=24/W_STEP=0.25`,
  `F_MAX=±12/F_STEP=0.5`), each row = 2 `ST_Intersects` calls (entry stone, exit
  stone) ⇒ **4753 states, 9506 ST_Intersects** for the map build. (The header text's
  "~79k ST_Intersects" figure does not describe this map; it matches the scale of the
  34-part page's 8-round disassembly instead — see §5. The 3D header wording is fixed
  in P0-4 to state the map's actual size.)
- Prepared statements: `p_lookup` (`SELECT blocked FROM esc_map WHERE wheel_deg=$1
  AND fork_deg=$2`) and `p_frame` (same lookup with `COALESCE(…,1)` — a grid miss is
  treated as blocked — plus a solid-profile `ST_Intersects` "clash3d" cross-check).
- Per frame: `physicsStep()` runs `EXECUTE p_frame(wheel_q, fork_q)` at an 8 ms
  virtual cadence; the wheel advances only when the SQL verdict is not blocked. The
  stone meshes glow hot (`RUBY_HOT`) driven by that same verdict.
- Ep5 solids: 4 parts (wheel rim, 2 stones, lever, balance rim) earcut-triangulated,
  inserted into a DB `solids` table, verified in SQL (volume via divergence theorem =
  2D area × thickness, open-edge count), wireframe overlays drawn from that table.
- Mini take-apart (wheel/fork/balance) with its own DB rounds; Start/Reset/Show
  collision map buttons; idle spin + real-time hands before Start.

### index2d.html — 2D engineering view (19.8 KB)

- Same escapement drawn orthographically on a 2D canvas (tooth/stone outlines,
  collision tint). Same `esc_map` build as the 3D page.
- Per-frame query is **not** a prepared statement on this page: the code comment
  records that prepared-statement parameter serialization is unreliable in this
  duckdb-wasm dev build, so it interpolates controlled numbers into
  `SELECT blocked FROM esc_map WHERE wheel_deg=… AND fork_deg=…`. Still one real SQL
  round-trip per frame; the database decides.
- Map heatmap button queries `esc_map` rows and draws them.

### index34.html — Ep5 full movement, 34 parts / 107 pieces (39.6 KB)

- Loads `movement_snapshot.json` (888 KB; `version:1`, source:
  "watchmaker-sql Ep5 pg -> duckdb port") — this is an **offline geometry snapshot**:
  parts (34), pieces (107) with WKT + z-bands, `way_out`, `stem_solid`,
  `take_apart_golden`. The Three.js meshes are assembled in the browser from it.
- Then fetches `04_take_apart.sql` (comments stripped, split on `;`) and executes it
  in DuckDB-WASM: `movement.part`, `movement.piece`, `v_way_out`, table macros
  `m_blocked(part, s)` and `m_blockers(part, s)` (see §5 for the predicate).
- **Disassembly loop** (`computeRounds()`): each round, for every non-base part not
  yet removed, one live query `SELECT blocked FROM m_blocked('…', s)`; released parts
  are inserted into the `movement.removal` ledger (so later rounds see them gone);
  loop until nothing releases (cap 15 rounds). The page also has a Step +1 round
  button, Assemble, and per-part `m_blockers()` lookup in the pin card.
- **Golden check**: `movement_snapshot.json.take_apart_golden` is 33 rows over
  rounds 1–8 with round sizes **10 / 4 / 3 / 5 / 6 / 3 / 1 / 1**. The page compares
  the live-computed per-round part sets against this golden table for rounds 1–8 and
  shows "GOLDEN MATCH ✓" / "MISMATCH ✗". The commit message of `ffab8d8` records that
  this matched in a real browser at the time.

## 5. 34-part 8-round take-apart — where the expected values come from

**Judgment logic** (all in `04_take_apart.sql`, executed live in the browser):

- Coordinate model: a z-axis part's world is a polygon in watch (x,y) occupying a
  z-band [z0, z1]; the stem is the single x-axis part, whose pieces are polygons in
  the (y,z) plane.
- `m_blocked(mover, s)` returns one row (1) if any still-present part stops it:
  - **Same axis (z/z)**: exact 2D test — `ST_Intersects` of the outlines **and**
    `ST_Area(ST_Intersection) > 1e-9` (true interior overlap, not edge touch) **and**
    the other part lies ahead on the mover's exit path (`s=+1: q.z1 > p.z0`;
    `s=-1: q.z0 < p.z1`).
  - **Across axes (stem ↔ z-parts)**: not an approximation — the exact 2D reduction
    of the 3D swept-solid test. The stem is a union of coaxial cylinders (stem
    r=0.45 over x 9.0–13.7, tube r=0.90 over 13.7–14.1, crown r=1.80 over 14.1–15.9,
    centered at (y=0, z=0.6)); a z-part meets the sweep iff, for some cylinder i, a
    point of its world has `x >= x0_i` and falls in the circle's y-projection strip
    `|y| <= w_i` with `w_i = sqrt(r_i² − d_i²)` (d_i = distance from z=0.6 to the
    part's z-band). The test is `ST_Intersects` of the clipped part against that
    strip, so it does **not** bridge holes — which is exactly what lets the stem pass
    the mainplate's stem notch. The symmetric case (z-part sliding through the
    cylinder's x-range) mirrors it.
- `v_way_out` gives each part its exit sign `s` (toward/away from the plate middle
  z=0.6; +1 for the x-axis stem). `is_base` parts (the mainplate) never move.
- Driver: one `m_blocked` query per part per round; released parts are recorded in
  the `removal` ledger; the golden table in the snapshot is the frozen reference
  output of the accepted native-DuckDB pipeline (see snapshot `source`).

**Expected result** (what "correct" means on this page): 8 rounds, 33 parts removed
(round sizes 10, 4, 3, 5, 6, 3, 1, 1), mainplate stays, live rounds 1–8 match the
golden table exactly ⇒ "GOLDEN MATCH ✓".

**Scope honesty** (must not be overclaimed in the showcase): the 34-part geometry is
an offline snapshot; the *verdicts* run live in DuckDB-WASM. The 3D escapement page is
a 2D-section collision model displayed in 3D — not a full 3D dynamics/force solver.

**Note on the "~79k" figure** (estimate, flagged): the 3D/2D page headers say "~79k
ST_Intersects calls". The escapement map build itself is 9506 calls (4753 rows × 2).
The 34-part page runs up to ~11k piece-pair tests per round (107 pieces) × up to 8
rounds, which is the scale ~79k can refer to. No run on this machine counted the
exact total; the 3D page's own header is corrected to describe its own map, and no
unverified number is added elsewhere.

## 6. Runtime environment facts

- Pages are pure static files for GitHub Pages: no backend, no build step.
- First browser load fetches the DuckDB-WASM bundle (~40 MB) + spatial extension from
  the jsDelivr CDN; the pages currently have **no byte-level download progress** —
  only a few status strings (`v-state`: "booting" / "installing spatial…" / "ready").
  This gap is what P0-3 (loading state machine) addresses.
- WebGL is required for the 3D pages; the 2D page needs only canvas + DuckDB-WASM.

## 7. Screenshots / console log

**截图：协调者补充**（此 lane 不运行无头浏览器；页面功能与 SQL 链如上所述，来自代码
与本地 curl/python 验证。浏览器实机截图、控制台日志、3D 运行画面由协调者在此处补充。）

## 8. How to reproduce this baseline from a clean checkout

```bash
cd <watchduck>
git checkout master   # or the showcase-p0 branch after the campaign
python3 -m http.server 8000   # → http://localhost:8000/index.html
python3 scripts/geometry.py   # expect the 4 numbers in §2 and ACCEPTANCE: PASS
```

Correctness gates: geometry.py `ACCEPTANCE: PASS`; on index34, after "Take apart",
"golden table: GOLDEN MATCH ✓" with 8 rounds / 33 parts; on the 3D/2D pages, the
watch runs when Start is pressed and the stone highlight follows the SQL verdict.
