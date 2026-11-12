/* =====================================================================
   The Watchmaker, Part 2  —  duckdb/04_take_apart.sql
   DuckDB port of pg/05_take_apart.sql.

   The peeling loop (pg: plpgsql) has no duckdb equivalent: the driver
   runs one blocking query per part per round and peels in Python,
   exactly as pg's loop did. Every geometric predicate here is plain
   SQL.

   Coordinates (v_piece): a z-axis part's world is a polygon in watch
   (x, y), occupying z in [z0, z1]. The stem (axis x) sits in place;
   its pieces are polygons in the watch (y, z) plane and their [z0,
   z1] columns are the watch-x extent.

   Same-axis pairs: the exact pg test — interior overlap of the
   outlines (pg ST_Relate '2********' == here ST_Area of the 2D
   intersection > 0) and q lying on p's exit path (s=+1 -> q.z1 > p.z0 ;
   s=-1 -> q.z0 < p.z1).

   The stem is the one x-axis part. pg tests its swept TIN solid
   against every other part's mesh with ST_3DIntersects (so the stem
   passes the mainplate's stem notch, because the TIN has the hole).
   duckdb's spatial has no 3D predicates, so the test is DERIVED, not
   approximated. The stem's solid is a union of coaxial cylinders
   along watch +x, one per piece, each a circle in the (y, z) plane
   centred at (y 0, z 0.6):
     stem  x 9.00..13.70  r 0.45
     tube  x 13.70..14.10 r 0.90
     crown x 14.10..15.90 r 1.80

   A z-axis part q occupies q.world (x, y) times its z band. A point
   (x, y, z) is in the stem's swept solid iff x >= x0_i for some
   cylinder i (sliding out +x, so cylinder i sweeps x in
   [x0_i, +inf)) and (y, z) is in circle_i. It is in q iff (x, y) is in
   q.world and z in [q.z0, q.z1]. So they meet iff, for some i:
     there is a point (x, y) of q.world with x >= x0_i whose y lies in
     the y-projection of (circle_i clipped to q's z band).
   circle_i clipped to q's z band [q.z0, q.z1] has y-projection
   [ -w_i, +w_i ],  w_i = sqrt(r_i^2 - d_i^2), where d_i is the
   distance from z=0.6 to [q.z0, q.z1] (0 if 0.6 is inside it);
   d_i > r_i means the band misses the circle (no meeting). That
   y-projection is a STRIP |y| <= w_i, and testing it against q.world
   clipped to x >= x0_i with ST_Intersects is an actual polygon overlap
   — it does NOT bridge a hole in the middle, which is exactly what
   lets the stem pass the mainplate's notch (the notch removes
   |y| <= 0.45 at x 9..13, so the strip |y| <= w_i finds no material
   there). Exact 2D, no approximation.

   Symmetric for a z-axis part p sliding out along z: clip p.world to
   the cylinder's x-range [x0_i, x1_i] and test the strip |y| <= w_i
   (with d_i measured against p's swept z band) the same way.
   ===================================================================== */

/* the stem's solid: one cylinder per piece (r, x-extent; centre y=0, z=0.6) */
CREATE TABLE movement.stem_solid AS
SELECT 'stem'  AS pc, 9.0  AS x0, 13.7 AS x1, 0.45 AS r
UNION ALL SELECT 'tube', 13.7, 14.1, 0.90
UNION ALL SELECT 'crown', 14.1, 15.9, 1.80;

/* the way each part leaves: away from the plate middle (z 0.6), or +x */
CREATE VIEW movement.v_way_out AS
SELECT p.part, p.axis, p.is_base,
       CASE WHEN p.axis = 'x' THEN 1
            WHEN (min(pc.z0) + max(pc.z1)) / 2 < 0.6 THEN -1 ELSE 1 END AS s
FROM movement.part AS p JOIN movement.piece AS pc ON pc.part = p.part
GROUP BY p.part, p.axis, p.is_base;

/* removal ledger — the driver inserts one row per part per round */
CREATE TABLE IF NOT EXISTS movement.removal (
  part   VARCHAR,
  round  INTEGER,
  dx     DOUBLE,
  dy     DOUBLE,
  dz     DOUBLE,
  level  INTEGER
);

/* blocked(mover, s): one row (1) if any still-present part stops it */
CREATE MACRO m_blocked(mp TEXT, ms INTEGER) AS TABLE
WITH pp AS (SELECT v.world AS g, v.z0, v.z1, p2.axis AS paxis
            FROM movement.v_piece v
            JOIN movement.part p2 ON p2.part = v.part
            WHERE v.part = mp),
     qq AS (SELECT v.part, v.world AS g, v.z0, v.z1, p2.axis AS qaxis
            FROM movement.v_piece v
            JOIN movement.part p2 ON p2.part = v.part
            WHERE v.part <> mp AND v.part NOT IN (SELECT part FROM movement.removal))
SELECT 1 AS blocked FROM (SELECT 1) src
WHERE EXISTS (
  SELECT 1 FROM pp, qq
  WHERE
    /* ---- same axis: both z-axis, exact 2D interior overlap + q on
              the exit path ---- */
    (pp.paxis = 'z' AND qq.qaxis = 'z' AND
     ST_Intersects(pp.g, qq.g)
     AND ST_Area(ST_Intersection(pp.g, qq.g)) > 1e-9
     AND ((ms > 0 AND qq.z1 > pp.z0 + 1e-9) OR (ms < 0 AND qq.z0 < pp.z1 - 1e-9)))
    OR
    /* ---- across axes: the exact 2D reduction of the 3D sweep ---- */
    (
      /* A: the mover is the stem sliding +x; q is a z-axis part.
            clip q to x >= x0_i, test the strip |y| <= w_i. */
      (pp.paxis = 'x' AND qq.qaxis = 'z' AND
       EXISTS (SELECT 1 FROM movement.stem_solid st
               WHERE GREATEST(qq.z0 - 0.6, 0.6 - qq.z1, 0.0) < st.r + 1e-9
                 AND ST_Intersects(
                       ST_Intersection(qq.g, ST_MakeEnvelope(st.x0, -1000, 1000, 1000)),
                       ST_MakeEnvelope(st.x0,
                                       -sqrt(st.r*st.r - GREATEST(qq.z0 - 0.6, 0.6 - qq.z1, 0.0)*GREATEST(qq.z0 - 0.6, 0.6 - qq.z1, 0.0)),
                                       1000,
                                        sqrt(st.r*st.r - GREATEST(qq.z0 - 0.6, 0.6 - qq.z1, 0.0)*GREATEST(qq.z0 - 0.6, 0.6 - qq.z1, 0.0))))))
      OR
      /* B: the mover is a z-axis part sliding along z; q is the stem.
            clip p to the cylinder x-range, test the strip |y| <= w_i
            against the cylinder x-range. */
      (pp.paxis = 'z' AND qq.qaxis = 'x' AND
       EXISTS (SELECT 1 FROM movement.stem_solid st
               WHERE GREATEST(
                       CASE WHEN ms > 0 THEN (CASE WHEN 0.6 < pp.z0 THEN pp.z0 - 0.6 ELSE 0.0 END)
                                        ELSE  (CASE WHEN 0.6 > pp.z1 THEN 0.6 - pp.z1 ELSE 0.0 END) END, 0.0) < st.r + 1e-9
                 AND ST_Intersects(
                       ST_Intersection(pp.g, ST_MakeEnvelope(st.x0, -1000, st.x1, 1000)),
                       ST_MakeEnvelope(st.x0,
                                       -sqrt(st.r*st.r - GREATEST(
                                             CASE WHEN ms > 0 THEN (CASE WHEN 0.6 < pp.z0 THEN pp.z0 - 0.6 ELSE 0.0 END)
                                                              ELSE  (CASE WHEN 0.6 > pp.z1 THEN 0.6 - pp.z1 ELSE 0.0 END) END, 0.0)
                                             *GREATEST(
                                             CASE WHEN ms > 0 THEN (CASE WHEN 0.6 < pp.z0 THEN pp.z0 - 0.6 ELSE 0.0 END)
                                                              ELSE  (CASE WHEN 0.6 > pp.z1 THEN 0.6 - pp.z1 ELSE 0.0 END) END, 0.0)),
                                       st.x1,
                                        sqrt(st.r*st.r - GREATEST(
                                             CASE WHEN ms > 0 THEN (CASE WHEN 0.6 < pp.z0 THEN pp.z0 - 0.6 ELSE 0.0 END)
                                                              ELSE  (CASE WHEN 0.6 > pp.z1 THEN 0.6 - pp.z1 ELSE 0.0 END) END, 0.0)
                                             *GREATEST(
                                             CASE WHEN ms > 0 THEN (CASE WHEN 0.6 < pp.z0 THEN pp.z0 - 0.6 ELSE 0.0 END)
                                                              ELSE  (CASE WHEN 0.6 > pp.z1 THEN 0.6 - pp.z1 ELSE 0.0 END) END, 0.0))))))
    )
)
;


/* diagnostic: which still-present parts block the mover (for debugging) */
CREATE MACRO m_blockers(mp TEXT, ms INTEGER) AS TABLE
WITH pp AS (SELECT v.world AS g, v.z0, v.z1, p2.axis AS paxis
            FROM movement.v_piece v
            JOIN movement.part p2 ON p2.part = v.part
            WHERE v.part = mp),
     qq AS (SELECT v.part, v.world AS g, v.z0, v.z1, p2.axis AS qaxis
            FROM movement.v_piece v
            JOIN movement.part p2 ON p2.part = v.part
            WHERE v.part <> mp AND v.part NOT IN (SELECT part FROM movement.removal))
SELECT DISTINCT qq.part AS blocker FROM pp, qq
WHERE
    (pp.paxis = 'z' AND qq.qaxis = 'z' AND
     ST_Intersects(pp.g, qq.g)
     AND ST_Area(ST_Intersection(pp.g, qq.g)) > 1e-9
     AND ((ms > 0 AND qq.z1 > pp.z0 + 1e-9) OR (ms < 0 AND qq.z0 < pp.z1 - 1e-9)));

/* exploded-view levels (last off sits nearest the plate) */
CREATE VIEW movement.v_levels AS
SELECT m.part, m.round, m.dx, m.dy, m.dz,
       g.last_round - m.round + 1 AS level
FROM movement.removal AS m
JOIN (SELECT dx, dy, dz, max(round) AS last_round FROM movement.removal GROUP BY dx, dy, dz) AS g
  ON g.dx = m.dx AND g.dy = m.dy AND g.dz = m.dz;
