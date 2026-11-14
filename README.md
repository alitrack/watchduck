# watchduck

**A mechanical watch escapement that runs inside DuckDB-WASM, in your browser. No server, no physics engine — every tick is a SQL query.**

[Chinese version: README_cn.md](README_cn.md)

Inspired by [“The Watchmaker: Building a Mechanical Watch in a Database”](https://sqlartist.github.io/posts/the-watchmaker-building-a-mechanical-watch-in-a-database/) (which used SQL Server Spatial, then PostGIS) and Bartosz Ciechanowski's [Mechanical Watch](https://ciechanow.ski/mechanical-watch/).

## What you see

A 15-tooth escape wheel, a pallet fork with two stones, and a balance wheel. The fork swings ±10° at 5 beats/second (18,000 bph, a classic movement rate). The wheel creeps forward half a tooth pitch per beat — **about 12° per beat — and nothing in the code ever says 12**. That number falls out of the shapes, exactly like in a real Swiss lever escapement.

## How it works — model the metal, not the maths

Every part is a polygon. The database is asked exactly one physical question, over and over:

```sql
SELECT ST_Intersects(
  ST_Rotate(tooth, wheel_angle),
  ST_Rotate(stone, fork_angle)
);
```

1. **Build the map (once, in SQL).** DuckDB-WASM loads the `spatial` extension, then cross-joins a grid of wheel angles × fork angles — ~9,500 states, ~79,000 `ST_Intersects` calls — into a `collision_map` table. This is the watch's entire physics, precomputed by the database.
2. **Run the watch (per frame, in SQL).** Each animation frame positions the fork with a triangle wave (like a real balance dwelling at the turn points) and asks the database one prepared query: *is this state blocked?* If free, the wheel advances; if blocked, the metal stops it. Lock → release → lock → release: the tick.
3. **Draw (canvas).** The browser only draws what DuckDB decided. It never decides anything.

The 3D view is pure presentation — the same DuckDB collision map and one-query-per-substep solver drive it, so the 3D and 2D views never disagree. Press **“Show collision map”** to see the actual table: red = metal on metal, green = the wheel may pass. The horizontal free corridor shifting with fork angle **is** the escapement.

## Try it

[**Live demo → alitrack.github.io/watchduck**](https://alitrack.github.io/watchduck/) — the hub page. Three demos, one engine:

- **[index34.html — Ep5 full movement (34 parts / 107 pieces)](https://alitrack.github.io/watchduck/index34.html)** — the complete calibre in 3D, with the **take-apart running live in DuckDB-WASM**: the disassembly loop (`m_blocked()`, one SQL per part per round) peels 8 rounds in the browser, matching the golden table of the [watchmaker-sql Ep5 reference](https://github.com/sqlartist/watchmaker-sql). Geometry is a pre-solved 868 KB snapshot (phases baked in) because the wasm engine's ~256 MB linear memory can't build 107 macro-generated pieces live — but every take-apart verdict is still a query the browser's database makes. See [`ep5_movement/`](ep5_movement/) for the SQL port + snapshot generator.
- **[escapement3d.html — 3-part escapement, 3D](https://alitrack.github.io/watchduck/escapement3d.html)** — Three.js rendering, solid metal escape wheel + ruby stones + balance, real-time ticking; ~79k `ST_Intersects` build the collision map live, a recursive SQL solver walks it tick by tick. The **3D cross-check** row in the HUD shows an independent verification: a Web Worker runs SFCGAL 2.3.0 in WebAssembly (CGAL, pure-exact Gmpq kernel) on the *same* geometry, recomputing each tick's clash as a **real volumetric intersection** of the rotated wheel-tooth prism against both pallet-stone prisms — one frame behind the 2D SQL verdict. Green = the two engines agree; amber = a contact-boundary cell (touching, sub-threshold volume); red = a divergence worth looking at. The 2D grid still drives everything — the worker is a check, not the engine.
- **[index2d.html — 2D engineering view](https://alitrack.github.io/watchduck/index2d.html)** — same engine, orthographic outlines, collision states marked on the drawing.

Each page is a self-contained static HTML (no build, no backend):

- ~40 MB DuckDB-WASM + spatial extension downloads on first load (cached after), works offline afterwards
- **Start / Pause / Reset**, and the live counter of the emergent **deg/beat** (theory: 12.00° = half the 24° tooth pitch)

## Repo layout

```
index.html              hub page — links the three demos (no engine, instant load)
escapement3d.html       the 3-part escapement app, 3D (static, no build step)
3d-verify-worker.mjs    the escapement's independent 3D cross-check (Web Worker)
sfcgal3d_32fix.wasm.js  SFCGAL 2.3.0 in wasm (CGAL Gmpq kernel), vendored — no CDN
sfcgal3d_32fix.wasm.wasm its wasm binary (import.meta.url resolves it in the worker)
index2d.html            the 3-part escapement, 2D engineering view
index34.html            the 34-part full movement + live wasm take-apart
movement_snapshot.json  assembled Ep5 state (world WKT per piece, phases baked in)
04_take_apart.sql       the m_blocked take-apart engine (runs in both native + wasm)
earcut.min.js           vendored earcut (index34 triangulates WKT profiles with it)
ep5_movement/           the native DuckDB port of the reference (SQL + drivers)
scripts/geometry.py     frozen part dimensions + the random search that found them
```

The geometry itself was found by random search against purely geometric acceptance criteria — lock at center swing, ~half-pitch release at extreme swing, zero dead zones. Run `python3 scripts/geometry.py` to verify the frozen geometry still passes acceptance; `--search` reruns the search.

## Why DuckDB (and why not something else)

The original article had to flee SQL Server 2025 for PostGIS because SQL Server has no `ST_Rotate` — the author's fastest rotate was string-editing WKT text. DuckDB's `spatial` extension ships rotation, translation and intersection out of the box, vectorized. The map build (~79k intersects) takes a few hundred milliseconds in WASM. SQLite could do this with a hand-written SAT query in pure SQL (we verified — it works, ~300× slower), and PostGIS remains the right tool for the article's eventual 3D keyless works — but for the 2D escapement, DuckDB-in-a-browser is enough. All the way down.

## Honest boundaries

- The balance "wheel" is drawn but its inertia is not simulated — the fork follows a prescribed 5 Hz triangle wave (a real balance's phase emerges from impulse; that's future work).
- Wheel motion while free is constant-speed, not torque-driven.
- 2D physics, like the article's Part 1 — but the escapement3d page cross-checks every tick against a real 3D SFCGAL-in-wasm volumetric test in a Web Worker (the "3D cross-check" HUD row), so the 2D reduction is continuously verified, not assumed.
- Teeth are convex quadrilaterals, not epicycloid profiles.

## License

MIT — see [LICENSE](LICENSE).
