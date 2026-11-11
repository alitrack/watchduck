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

Press **“Show collision map”** to see the actual table: red = metal on metal, green = the wheel may pass. The horizontal free corridor shifting with fork angle **is** the escapement.

## Try it

[**Live demo → alitrack.github.io/watchduck**](https://alitrack.github.io/watchduck/) — the whole engine is a static HTML page:

- ~40 MB DuckDB-WASM + spatial extension downloads on first load (cached after), works offline afterwards
- **Start / Pause / Reset**, and the live counter of the emergent **deg/beat** (theory: 12.00° = half the 24° tooth pitch)

## Repo layout

```
index.html            the whole app (static, no build step)
scripts/geometry.py   frozen part dimensions + the random search that found them
```

The geometry itself was found by random search against purely geometric acceptance criteria — lock at center swing, ~half-pitch release at extreme swing, zero dead zones. Run `python3 scripts/geometry.py` to verify the frozen geometry still passes acceptance; `--search` reruns the search.

## Why DuckDB (and why not something else)

The original article had to flee SQL Server 2025 for PostGIS because SQL Server has no `ST_Rotate` — the author's fastest rotate was string-editing WKT text. DuckDB's `spatial` extension ships rotation, translation and intersection out of the box, vectorized. The map build (~79k intersects) takes a few hundred milliseconds in WASM. SQLite could do this with a hand-written SAT query in pure SQL (we verified — it works, ~300× slower), and PostGIS remains the right tool for the article's eventual 3D keyless works — but for the 2D escapement, DuckDB-in-a-browser is enough. All the way down.

## Honest boundaries

- The balance "wheel" is drawn but its inertia is not simulated — the fork follows a prescribed 5 Hz triangle wave (a real balance's phase emerges from impulse; that's future work).
- Wheel motion while free is constant-speed, not torque-driven.
- 2D only, like the article's Part 1. The 3D keyless works is where PostGIS/SFCGAL would win.
- Teeth are convex quadrilaterals, not epicycloid profiles.

## License

MIT — see [LICENSE](LICENSE).
