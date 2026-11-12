# Ep5 full-calibre movement in DuckDB (34-part, take-apart verified)

The Watchmaker, Part 2 (`../watchmaker-sql` pg reference) fully ported to plain
DuckDB SQL. No PostGIS, no plpgsql, no spatial-3d — just the CDN `spatial`
extension (GEOS 2D) plus a small Python driver for the two things that are
stateful loops in the original.

## What's here

| file | port of | notes |
|---|---|---|
| `sql/01_schema.sql` | `pg/01_schema.sql` | same tables, same frames |
| `sql/02_profiles.sql` | `pg/02_profiles.sql` | every profile is a table macro; the involute-endpoint bisection (plpgsql 60-iter) is a `WITH RECURSIVE` CTE |
| `sql/03_calibre.sql` + `03_calibre_b.sql` | `pg/03_calibre.sql` | 34 parts, arbor tree walk (recursive CTE), bridges, hands; `piece.world` is a **view** (phase in the `part` table, world recomputes) |
| `sql/04_take_apart.sql` | `pg/05_take_apart.sql` (geometry half) | `m_blocked(p, s)`: coaxial = 2D world overlap + z-band check; cross-axis (the stem) = the **strict** 2D reduction of `ST_3DIntersects` (swept solid = yz section × x range; a hole in the clipping polygon stays a hole because we test real polygon overlap, never envelopes) |
| `run_native.py` | `pg/05_take_apart.sql` (loop half) + `pg/03_calibre.sql` `clear_phase`/`phase_meshes`/`phase_click` | assembles the 5 SQL files, phases the going train to max backlash, then peels: one `m_blocked` query per part per round |

## The wasm page (index34.html, full movement in the browser)

The DuckDB-WASM engine cannot build all 107 piece geometries live (its
single-threaded linear memory tops out ~256 MB and the macro pipeline runs
out in `03_calibre_b`), so the page takes a **static snapshot** of the
assembled state — `gen_snapshot.py` runs the verified native pipeline
(assemble → phase → golden check) and dumps `movement_snapshot.json`
(868 KB, world WKT per piece, phases baked into the geometry). The browser
loads the snapshot in ~150 ms and then runs the **take-apart loop entirely
in DuckDB-WASM**: `m_blocked()` per part per round, one SQL each, parts
explode along the DB-issued exit axis. The live loop reproduces the golden
table in the browser (verified headless: `GOLDEN MATCH ✓`, 0 page errors).

Run: `python3 gen_snapshot.py [base] [out.json]` (needs duckdb + spatial;
aborts if the golden table regresses).

## Run

```sh
pip install duckdb        # 1.4.x
python3 run_native.py
```

(assembled in ~30s on a 32-core Mac; the heavy part is 107-part geometry
assembly, not the peeling)

## Acceptance — the README golden table, matched exactly

```
round 1: back=[7 screws]        front=[minute, seconds hand]  side=[stem]
round 2: back=[balance cock, click, ratchet]  front=[hour hand]
round 3: back=[barrel bridge, hairspring]     front=[dial]
round 4: back=[balance, barrel cover, pallet-bridge screw, train bridge] front=[hour wheel]
round 5: back=[barrel arbor, mainspring, pallet bridge, third wheel] front=[cannon pinion, minute wheel]
round 6: back=[barrel, escape wheel, pallet fork]
round 7: back=[fourth wheel]
round 8: back=[centre wheel]
```

All 33 non-base parts removed, 8 rounds, every part in its golden round.

## Design decisions (and the bugs they came from)

- **No `ST_3DIntersects` needed.** The only cross-axis part is the stem
  (x-axis cylinder). Its swept solid ∩ a z-axis prism reduces exactly to:
  (a) z-band overlap → allowed x window on the stem; (b) `ST_Intersects`
  between the stem's yz-section (clipped to that window) and the other
  part's world polygon. Mathematically equivalent to the 3D test, not an
  approximation — holes (mainplate stem aperture) behave correctly because
  (b) is real polygon overlap.
- **Arbor walk: `0.0::DOUBLE`.** The recursive CTE base case `SELECT 0.0 AS x`
  is a `DECIMAL(2,1)` in DuckDB; every computed arbor coordinate came out
  rounded to 0.1 mm — enough to push every gear mesh ~0.03 mm closer than
  pitch so the teeth overlapped at *all* phases and `clear_phase` found no
  backlash. Casting the base case fixed it (diff vs `(z1+z2)·m/2` → 0.0000).
- **`clear_phase` step = one tooth pitch.** `360.0 / teeth * j / steps`
  (pg); writing `* teeth` instead of `/ teeth` makes an 80-tooth wheel jump
  120° per sub-step and never clear.
- **Piece names are data.** The ratchet part's disc is piece `'wheel'` (not
  `'ratchet'`); a wrong piece name in `phase_click` selected NULL, `ST_Intersects(NULL,…)` → NULL, and the click "never touches" — silently rotated to the sweep limit while still interpenetrating, deadlocking the round-2 click/ratchet pair.
- **DuckDB engine bug (worked around):** a table macro used as a scalar
  subquery *argument* inside another table macro crashes ("index 2 within
  vector of size 2"). Anything that feeds one macro into another goes
  through a real CTE/table first.
- Skipped deliberately: `pg/04_solids.sql` (3D TIN meshes) — the take-apart
  blocking test needs only the 2D sections + z bands, which `v_piece`
  already carries.
