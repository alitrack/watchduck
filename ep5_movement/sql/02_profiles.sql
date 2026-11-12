/* =====================================================================
   The Watchmaker, Part 2  —  duckdb/02_profiles.sql
   DuckDB port of pg/02_profiles.sql. Same shapes, point for point.

   DuckDB has no plpgsql; scalar macros cannot take GEOMETRY[] or contain
   FROM; and a TABLE macro may only appear in FROM/CTE position, never
   inside an expression. So every primitive is a TABLE macro returning a
   single `g` row; composites build their sub-pieces as CTEs and combine
   them with ST_Union / ST_Difference in the final SELECT. The sixty-
   halving bisection (epi_end) is a recursive CTE. Same numbers.
   ===================================================================== */

/* polar point at radius r, angle deg (anticlockwise from +x) about (cx,cy) */
CREATE MACRO m_polar(r DOUBLE, deg DOUBLE, cx DOUBLE, cy DOUBLE)
  AS ST_MakePoint(cx + r*cos(radians(deg)), cy + r*sin(radians(deg)));

/* the epicycloid roll test, and the sixty-halving that finds the roll end */
CREATE MACRO m_epitest(a DOUBLE, rho DOUBLE, ra DOUBLE, g DOUBLE, mode TEXT, mid DOUBLE)
  AS CASE WHEN mode = 'R'
          THEN sqrt(pow((a+rho)*cos(mid) - rho*cos((a+rho)/rho*mid),2)
                 + pow((a+rho)*sin(mid) - rho*sin((a+rho)/rho*mid),2)) - ra
          ELSE degrees(atan2((a+rho)*sin(mid) - rho*sin((a+rho)/rho*mid),
                             (a+rho)*cos(mid) - rho*cos((a+rho)/rho*mid))) - g END;

CREATE MACRO m_bisect(a DOUBLE, rho DOUBLE, ra DOUBLE, g DOUBLE, mode TEXT) AS TABLE
  WITH RECURSIVE r(i, lo, hi) AS (
    SELECT 0, 0.0::DOUBLE, LEAST(pi()*rho/a, pi()/2)
    UNION ALL
    SELECT i+1,
           CASE WHEN m_epitest(a, rho, ra, g, mode, (lo+hi)/2) >= 0 THEN lo ELSE (lo+hi)/2 END,
           CASE WHEN m_epitest(a, rho, ra, g, mode, (lo+hi)/2) >= 0 THEN (lo+hi)/2 ELSE hi END
    FROM r WHERE i < 59)
  SELECT hi AS roll_end FROM r WHERE i = 59;

/* ---- primitives (one geometry each) ---- */

/* an n-gon circle about (cx,cy), closed */
CREATE MACRO m_circle(cx DOUBLE, cy DOUBLE, r DOUBLE, n INT) AS TABLE
  SELECT ST_MakePolygon(ST_MakeLine(list(m ORDER BY j)::GEOMETRY[])) AS g FROM (
    SELECT j, m_polar(r, 360.0*j/n, cx, cy) AS m FROM range(n) x(j)
    UNION ALL SELECT n, m_polar(r, 0, cx, cy));

/* ring with a concentric hole */
CREATE MACRO m_annulus(cx DOUBLE, cy DOUBLE, ro DOUBLE, ri DOUBLE, n INT) AS TABLE
  SELECT ST_Difference(bo.g, sm.g) AS g
  FROM m_circle(cx, cy, ro, n) bo, m_circle(cx, cy, ri, n) sm;

/* a gear of z teeth, module m: epicycloid addendum, radial dedendum */
CREATE MACRO m_gear(z INT, m DOUBLE, rho DOUBLE, kind TEXT) AS TABLE
WITH f AS (
  SELECT m*z/2.0 AS a, m*z/2.0 + fm.ha*m AS ra, m*z/2.0 - fm.hf*m AS rr,
         degrees(fm.s*m/2/(m*z/2.0)) AS g, 360.0/z AS pitch, coalesce(fm.flank_pts, 12) AS np
  FROM movement.form fm WHERE fm.kind = kind),
c AS (
  SELECT f.*, e1.roll_end AS tr, e2.roll_end AS ta,
         LEAST(e1.roll_end, e2.roll_end) AS tend, e2.roll_end <= e1.roll_end AS pointed
  FROM f, (SELECT * FROM m_bisect(f.a, rho, f.ra, f.g, 'R')) e1,
           (SELECT * FROM m_bisect(f.a, rho, f.ra, f.g, 'A')) e2),
flank AS (                                   -- trailing addendum flank, pitch circle up
  SELECT j, -c.g + degrees(atan2(p.ey, p.ex)) AS d, sqrt(p.ex*p.ex + p.ey*p.ey) AS rad
  FROM c, range(c.np+1) x(j),
       (SELECT (c.a+rho)*cos(c.tend*j/c.np) - rho*cos((c.a+rho)/rho*c.tend*j/c.np) AS ex,
               (c.a+rho)*sin(c.tend*j/c.np) - rho*sin((c.a+rho)/rho*c.tend*j/c.np) AS ey) p),
lf AS (SELECT fl.*, c.pointed, c.np, c.g, c.rr, c.ra, c.pitch FROM flank fl CROSS JOIN c),
tooth AS (
  SELECT 0 AS seq, -c.g AS d, c.rr AS rad FROM c
  UNION ALL SELECT 1 + j, d, rad FROM flank
  UNION ALL SELECT 1000 + t, fl.d - 2*fl.d*t/4.0, fl.ra
         FROM lf fl, range(1,4) x(t) WHERE fl.j = fl.np AND NOT fl.pointed
  UNION ALL SELECT 2000 + (fl.np - fl.j), -fl.d, fl.rad FROM lf fl WHERE NOT fl.pointed OR fl.j < fl.np
  UNION ALL SELECT 3000, fl.g, fl.rr FROM lf fl
  UNION ALL SELECT 3000 + t, fl.g + (fl.pitch - 2*fl.g)*t/4.0, fl.rr FROM lf fl, range(1,4) x(t)),
pts AS (
  SELECT k*100000 + t.seq AS ord, m_polar(t.rad, k*c.pitch + t.d, 0, 0) AS pt
  FROM c, range(z) x(k), tooth t
  UNION ALL
  SELECT z*100000 + 5 AS ord, m_polar(c.rr, -c.g, 0, 0) FROM c)      -- close: repeat first point
SELECT ST_MakePolygon(ST_MakeLine(list(pt ORDER BY ord)::GEOMETRY[])) AS g
FROM pts;

/* a pinion of n leaves: radial flanks, round tip */
CREATE MACRO m_pinion(n INT, m DOUBLE) AS TABLE
WITH f AS (
  SELECT m*n/2.0 AS rp, m*n/2.0 - fm.hf*m AS rr, degrees(fm.s*m/2/(m*n/2.0)) AS g,
         360.0/n AS pitch, fm.tip_step AS ts FROM movement.form fm WHERE fm.kind = 'leaf'),
c AS (SELECT f.*, f.rp*cos(radians(f.g)) AS cx, f.rp*sin(radians(f.g)) AS half FROM f),
leaf AS (
  SELECT 0 AS seq, -c.g AS d, c.rr AS rad FROM c
  UNION ALL SELECT 1, -c.g, c.rp FROM c
  UNION ALL SELECT 1000 + a, degrees(atan2(p.py, p.px)), sqrt(p.px*p.px + p.py*p.py)
         FROM c, range(-90 + c.ts, 90 - c.ts + 1, c.ts) x(a),
              (SELECT c.cx + c.half*cos(radians(a)) AS px, c.half*sin(radians(a)) AS py) p
  UNION ALL SELECT 2000, c.g, c.rp FROM c
  UNION ALL SELECT 2001, c.g, c.rr FROM c
  UNION ALL SELECT 2001 + t, c.g + (c.pitch - 2*c.g)*t/4.0, c.rr FROM c, range(1,4) x(t)),
pts AS (
  SELECT k*100000 + l.seq AS ord, m_polar(l.rad, k*c.pitch + l.d, 0, 0) AS pt
  FROM c, range(n) x(k), leaf l
  UNION ALL
  SELECT n*100000 + 5 AS ord, m_polar(c.rr, -c.g, 0, 0) FROM c)     -- close: repeat first point
SELECT ST_MakePolygon(ST_MakeLine(list(pt ORDER BY ord)::GEOMETRY[])) AS g
FROM pts;

/* a wheel cut to a rim, arms and a hub, with an arbor hole */
CREATE MACRO m_crossed(outline GEOMETRY, rim DOUBLE, hub DOUBLE, hole DOUBLE,
                       arms INT, arm_w DOUBLE, arm0 DOUBLE) AS TABLE
WITH ann AS (SELECT * FROM m_annulus(0,0,rim,hub,128)),
     cut AS (SELECT ST_Union_Agg(ST_Buffer(ST_MakeLine(m_polar(0,0,0,0), m_polar(rim+0.1, arm0 + 360.0/arms*k, 0, 0)), arm_w, 4)) AS g
             FROM range(arms) x(k)),
     hole_c AS (SELECT * FROM m_circle(0,0,hole,24)),
     rim_open AS (SELECT ST_Difference(ann.g, cut.g) AS g FROM ann, cut)
SELECT ST_Difference(ST_Difference(outline, rim_open.g), hole_c.g) AS g
FROM rim_open, hole_c;

/* ---- escapement geometry (escapement units, wheel at origin) ---- */
CREATE MACRO m_esc_p() AS (SELECT ST_MakePoint(0, r/cos(radians(30))) FROM movement.esc_spec);
CREATE MACRO m_esc_k() AS (SELECT radians(1) * r * tan(radians(30)) FROM movement.esc_spec);

/* fifteen club teeth */
CREATE MACRO m_escape_wheel() AS TABLE
WITH s AS (SELECT r, rr, club_rise, teeth, 360.0/teeth AS pitch FROM movement.esc_spec),
tooth AS (
  SELECT v.seq, v.d::DOUBLE AS d, v.rad FROM s,
         (VALUES (1,-11.0,s.rr),(2,-8.5,7.9),(3,-6.5,8.8),(4,-4.5,9.55),(5,-3.0,s.r),
                 (6,-2.0,s.r-s.club_rise/3),(7,-1.0,s.r-2*s.club_rise/3),(8,0.0,s.r-s.club_rise),
                 (9,-1.2,9.05),(10,-2.6,8.2),(11,-4.2,7.45),(12,-5.0,s.rr)) v(seq,d,rad)
  UNION ALL
  SELECT 12 + j, -5.0 + 18.0*j/8, s.rr FROM s, range(1,8) x(j)),
pts AS (
  SELECT k*100000 + t.seq AS ord, m_polar(t.rad, k*s.pitch + t.d, 0, 0) AS pt
  FROM s, range(s.teeth) x(k), tooth t
  UNION ALL
  SELECT s.teeth*100000 + 5 AS ord, m_polar(s.rr, -11.0, 0, 0) FROM s)  -- close: repeat first point
SELECT ST_MakePolygon(ST_MakeLine(list(pt ORDER BY ord)::GEOMETRY[])) AS g
FROM pts;

/* the wheel as made: teeth, five crossings, hub, arbor hole */
CREATE MACRO m_escape_wheel_display() AS TABLE
WITH w AS (SELECT * FROM m_escape_wheel()),
     ann AS (SELECT * FROM m_annulus(0,0,6.4,2.0,128)),
     cut AS (SELECT ST_Union_Agg(ST_Buffer(ST_MakeLine(m_polar(0,0,0,0), m_polar(6.6, 90 + 72*k, 0, 0)), 0.45, 4)) AS g
             FROM range(5) x(k)),
     rim AS (SELECT ST_Difference(ann.g, cut.g) AS g FROM ann, cut),
     hole AS (SELECT * FROM m_circle(0,0,0.5,24))
SELECT ST_Difference(ST_Difference(w.g, rim.g), hole.g) AS g
FROM w, rim, hole;

/* a pallet stone; lock_at = angle about the wheel of its locking corner */
CREATE MACRO m_stone(lock_at DOUBLE) AS TABLE
WITH c AS (
  SELECT (s.r + s.lock_deg*k.kk)*cos(radians(lock_at)) AS clx,
         (s.r + s.lock_deg*k.kk)*sin(radians(lock_at)) AS cly,
         (s.r + (s.lock_deg-s.lift_deg)*k.kk)*cos(radians(lock_at + s.stone_w)) AS cex,
         (s.r + (s.lock_deg-s.lift_deg)*k.kk)*sin(radians(lock_at + s.stone_w)) AS cey,
         cos(radians(lock_at + s.draw_deg)) AS fx, sin(radians(lock_at + s.draw_deg)) AS fy,
         cos(radians(lock_at + s.stone_w)) AS ux, sin(radians(lock_at + s.stone_w)) AS uy
  FROM movement.esc_spec s, (SELECT m_esc_k() AS kk) k)
SELECT ST_MakePolygon(ST_MakeLine(list(pp ORDER BY i)::GEOMETRY[])) AS g
FROM c, (
  SELECT 0 AS i, ST_MakePoint(clx + 2.2*fx, cly + 2.2*fy) AS pp FROM c
  UNION ALL SELECT 1, ST_MakePoint(clx, cly) FROM c
  UNION ALL SELECT 2, ST_MakePoint(cex, cey) FROM c
  UNION ALL SELECT 3, ST_MakePoint(cex + 2.9*ux, cey + 2.9*uy) FROM c
  UNION ALL SELECT 4, ST_MakePoint(clx + 2.2*fx, cly + 2.2*fy) FROM c) v(i, pp);

/* the lever, arbor to fork; the horns stop at 9.95 */
CREATE MACRO m_lever() AS TABLE
WITH p AS (SELECT m_esc_p() AS pp),
ring AS (SELECT ST_MakePolygon(ST_MakeLine(list(pp ORDER BY i)::GEOMETRY[])) AS g
         FROM (VALUES
           (0, ST_MakePoint(-0.45,0.0)),(1,ST_MakePoint(-0.35,8.0)),(2,ST_MakePoint(-1.0,8.6)),
           (3,ST_MakePoint(-1.0,9.6)),(4,ST_MakePoint(-0.75,9.95)),(5,ST_MakePoint(-0.4,9.95)),
           (6,ST_MakePoint(-0.4,9.25)),(7,ST_MakePoint(0.4,9.25)),(8,ST_MakePoint(0.4,9.95)),
           (9,ST_MakePoint(0.75,9.95)),(10,ST_MakePoint(1.0,9.6)),(11,ST_MakePoint(1.0,8.6)),
           (12,ST_MakePoint(0.35,8.0)),(13,ST_MakePoint(0.45,0.0)),
           (14,ST_MakePoint(-0.45,0.0))) v(i,pp))
SELECT ST_Translate(ring.g, ST_X(p.pp), ST_Y(p.pp)) AS g
FROM ring, p;

/* pallet body: a bar stone-to-stone through the arbor, plus the boss */
CREATE MACRO m_pallet_body() AS TABLE
WITH s AS (SELECT r, entry_lock, exit_lock, stone_w FROM movement.esc_spec),
c AS (SELECT s.r AS r, s.entry_lock + s.stone_w/2 AS el, s.exit_lock + s.stone_w/2 AS xl,
       ST_X(m_esc_p()) AS px, ST_Y(m_esc_p()) AS py
       FROM s),
bar AS (SELECT ST_Buffer(ST_MakeLine([m_polar(c.r + 2.4, c.el, 0, 0),
                                      ST_MakePoint(c.px, c.py),
                                      m_polar(c.r + 2.4, c.xl, 0, 0)]::GEOMETRY[]), 0.6, 16) AS g FROM c),
boss AS (SELECT (SELECT g FROM m_circle(c2.px, c2.py, 1.3, 64)) AS g FROM c c2),
hole AS (SELECT (SELECT g FROM m_circle(c2.px, c2.py, 0.35, 24)) AS g FROM c c2),
u AS (SELECT ST_Union(bar.g, boss.g) AS g FROM bar, boss)
SELECT ST_Difference(u.g, hole.g) AS g
FROM u, hole;

/* banking pins: they meet the lever's edge 4.5 along it at +/- BankDeg */
CREATE MACRO m_banking_pins() AS TABLE
WITH p AS (SELECT ST_X(m_esc_p()) AS px, ST_Y(m_esc_p()) AS py,
                  (SELECT bank_deg FROM movement.esc_spec) AS bank_deg,
                  0.45 - 0.10*4.5/8.0 AS hw, 0.3 AS pr),
c AS (SELECT pr,
      ST_Translate(ST_Rotate(ST_Translate(ST_MakePoint(px - (hw+pr), py + 4.5), -px, -py), radians(bank_deg)), px, py) AS l,
      ST_Translate(ST_Rotate(ST_Translate(ST_MakePoint(px + (hw+pr), py + 4.5), -px, -py), -radians(bank_deg)), px, py) AS r FROM p),
l AS (SELECT (SELECT g FROM m_circle(ST_X(c2.l), ST_Y(c2.l), c2.pr, 48)) AS g FROM c c2),
r AS (SELECT (SELECT g FROM m_circle(ST_X(c2.r), ST_Y(c2.r), c2.pr, 48)) AS g FROM c c2)
SELECT ST_Union(l.g, r.g) AS g
FROM l, r;

/* =====================================================================
   POWER (the barrel arbor at the origin)
   ===================================================================== */
CREATE OR REPLACE TABLE movement.power_spec (
    id INT PRIMARY KEY,
    ratchet_teeth INT, ratchet_tip DOUBLE, ratchet_root DOUBLE, pawl_x DOUBLE, pawl_y DOUBLE,
    rb DOUBLE, ra DOUBLE, t DOUBLE, l DOUBLE, pts_per_turn INT, free_turns DOUBLE, min_pack DOUBLE
);
INSERT INTO movement.power_spec VALUES (1, 36, 4.40, 3.95, 5.7, -3.4, 5.0, 1.6, 0.10, 350.0, 48, 1.25, 1.0);

/* sawtooth ratchet, walked anticlockwise */
CREATE MACRO m_ratchet() AS TABLE
WITH s AS (SELECT * FROM movement.power_spec WHERE id = 1)
SELECT ST_MakePolygon(ST_MakeLine(list(p ORDER BY k, i)::GEOMETRY[])) AS g
FROM (
  SELECT k, 0 AS i, m_polar(s.ratchet_root, k*360.0/s.ratchet_teeth, 0, 0) AS p FROM s, range(s.ratchet_teeth) x(k)
  UNION ALL
  SELECT k, 1, m_polar(s.ratchet_tip, k*360.0/s.ratchet_teeth + 0.4, 0, 0) FROM s, range(s.ratchet_teeth) x(k)
  UNION ALL
  SELECT s.ratchet_teeth, 2, m_polar(s.ratchet_root, 0, 0, 0) FROM s) v(k, i, p);

/* the click at rest: a head in the gap, an arm 0.6 wide, a boss on its pivot */
CREATE MACRO m_click() AS TABLE
WITH a AS (SELECT 4.72*cos(radians(-3.0)) AS ax, 4.72*sin(radians(-3.0)) AS ay,
       5.7 AS bx, -3.4 AS byy FROM (SELECT 1)),
n AS (SELECT a.*, -(byy - ay)/sqrt(pow(bx-ax,2) + pow(byy-ay,2)) * 0.3 AS nx,
                 (bx - ax)/sqrt(pow(bx-ax,2) + pow(byy-ay,2)) * 0.3 AS ny FROM a),
head AS (SELECT ST_MakePolygon(ST_MakeLine(list(pp ORDER BY i)::GEOMETRY[])) AS g FROM (
   SELECT 0 AS i, m_polar(4.00, -0.6, 0, 0) AS pp
   UNION ALL SELECT 1, m_polar(4.62, -0.6, 0, 0)
   UNION ALL SELECT 2, m_polar(5.05, -1.5, 0, 0)
   UNION ALL SELECT 3, m_polar(4.75, -4.6, 0, 0)
   UNION ALL SELECT 4, m_polar(4.30, -4.0, 0, 0)
   UNION ALL SELECT 5, m_polar(4.00, -0.6, 0, 0)) v),
arm AS (SELECT ST_MakePolygon(ST_MakeLine(list(pp ORDER BY i)::GEOMETRY[])) AS g FROM n, (
   SELECT 0 AS i, ST_MakePoint(ax+nx, ay+ny) AS pp FROM n
   UNION ALL SELECT 1, ST_MakePoint(bx+nx, byy+ny) FROM n
   UNION ALL SELECT 2, ST_MakePoint(bx-nx, byy-ny) FROM n
   UNION ALL SELECT 3, ST_MakePoint(ax-nx, ay-ny) FROM n
   UNION ALL SELECT 4, ST_MakePoint(ax+nx, ay+ny) FROM n) v),
ab AS (SELECT (SELECT g FROM m_circle(n2.ax, n2.ay, 0.3, 32)) AS g FROM n n2),
bb AS (SELECT (SELECT g FROM m_circle(n2.bx, n2.byy, 0.6, 32)) AS g FROM n n2),
hole AS (SELECT (SELECT g FROM m_circle(n2.bx, n2.byy, 0.18, 16)) AS g FROM n n2),
u1 AS (SELECT ST_Union(head.g, arm.g) AS g FROM head, arm),
u2 AS (SELECT ST_Union(ST_Union(u1.g, ab.g), bb.g) AS g FROM u1, ab, bb)
SELECT ST_Difference(u2.g, hole.g) AS g
FROM u2, hole;

/* Archimedean spiral points: radius r0 + dr*s after s turns */
CREATE MACRO m_spiral_pts(r0 DOUBLE, dr DOUBLE, a0 DOUBLE, turns DOUBLE, dir INT, per INT) AS TABLE
WITH c AS (SELECT GREATEST(2, CAST(CEIL(turns*per) AS INT) + 1) AS n)
SELECT j, m_polar(r0 + dr*(turns*j/(n-1.0)), a0 + dir*360.0*(turns*j/(n-1.0)), 0, 0) AS pt
FROM c, range(c.n) x(j);

/* the mainspring's length for so many turns packed in and out */
CREATE MACRO m_spring_len(n_in DOUBLE, n_out DOUBLE)
  AS (SELECT 2*pi()*n_in*(ra + t/2 + t*n_in/2) + 2*pi()*n_out*(rb - t/2 - t*n_out/2)
       + pi()*free_turns*((ra + t/2 + t*n_in) + (rb - t/2 - t*n_out))
       FROM movement.power_spec WHERE id = 1);

/* turns of spring when let down and when fully wound: two sixty-halvings.
   side 0: min pack on the arbor -> let_down; side 1: min pack on the wall -> wound. */
CREATE MACRO m_spring_limits() AS TABLE
WITH RECURSIVE s AS (SELECT * FROM movement.power_spec WHERE id = 1),
hi0 AS (SELECT (rb - ra)/t - min_pack - free_turns AS hi FROM s),
r0 AS (
  SELECT 0 AS i, 0.0::DOUBLE AS lo, hi AS hi FROM hi0
  UNION ALL
  SELECT i+1,
    CASE WHEN m_spring_len(min_pack, (lo+hi)/2) > l THEN lo ELSE (lo+hi)/2 END,
    CASE WHEN m_spring_len(min_pack, (lo+hi)/2) > l THEN (lo+hi)/2 ELSE hi END
  FROM r0, s WHERE i < 59),
r1 AS (
  SELECT 0 AS i, 0.0::DOUBLE AS lo, hi AS hi FROM hi0
  UNION ALL
  SELECT i+1,
    CASE WHEN m_spring_len((lo+hi)/2, min_pack) > l THEN lo ELSE (lo+hi)/2 END,
    CASE WHEN m_spring_len((lo+hi)/2, min_pack) > l THEN (lo+hi)/2 ELSE hi END
  FROM r1, s WHERE i < 59)
SELECT (SELECT min_pack + free_turns + hi FROM r0 WHERE i = 59) AS let_down,
       (SELECT min_pack + free_turns + hi FROM r1 WHERE i = 59) AS wound
FROM s;

/* the hairspring: twelve turns from r 0.45 to 2.2, breathing with dbeta */
CREATE MACRO m_hairspring_line(dbeta DOUBLE, per INT) AS TABLE
SELECT ST_MakeLine(list(pt ORDER BY k)::GEOMETRY[]) AS g
FROM range(12*per + 1) x(k),
     (SELECT m_polar(0.45 + 1.75*(k/(12.0*per)), -90 + 360.0*12*(k/(12.0*per)) + dbeta*(1 - k/(12.0*per)), 0, 0) AS pt
      FROM range(12*per + 1) x(k)) h;

/* =====================================================================
   SMALL THINGS
   ===================================================================== */
/* a knurled edge: n ridges between radii r_in and r_out */
CREATE MACRO m_knurl(cx DOUBLE, cy DOUBLE, ro DOUBLE, ri DOUBLE, n INT) AS TABLE
  SELECT ST_MakePolygon(ST_MakeLine(list(m ORDER BY j)::GEOMETRY[])) AS g FROM (
    SELECT j, m_polar(CASE WHEN j % 2 = 0 THEN ro ELSE ri END, 180.0*j/n, cx, cy) AS m
    FROM range(2*n) x(j)
    UNION ALL SELECT 2*n, m_polar(ro, 0, cx, cy));

/* a hand pointing to 12, with a boss and an n-gon bore */
CREATE MACRO m_hand(tail DOUBLE, w DOUBLE, len DOUBLE, tip DOUBLE, boss DOUBLE, bore DOUBLE, bore_n INT) AS TABLE
WITH body AS (SELECT ST_MakePolygon(ST_MakeLine(list(pp ORDER BY i)::GEOMETRY[])) AS g FROM (
    SELECT 0 AS i, ST_MakePoint(-w, -tail) AS pp
    UNION ALL SELECT 1, ST_MakePoint(w, -tail)
    UNION ALL SELECT 2, ST_MakePoint(w*0.75, len)
    UNION ALL SELECT 3, ST_MakePoint(0, len + tip)
    UNION ALL SELECT 4, ST_MakePoint(-w*0.75, len)
    UNION ALL SELECT 5, ST_MakePoint(-w, -tail)) v),
b AS (SELECT (SELECT g FROM m_circle(0, 0, boss, 48)) AS g),
bo AS (SELECT (SELECT g FROM m_circle(0, 0, bore, bore_n)) AS g),
u AS (SELECT ST_Union(body.g, b.g) AS g FROM body, b)
SELECT ST_Difference(u.g, bo.g) AS g
FROM u, bo;

/* the mainspring as one line: inner pack, free coil, outer pack.
   n_in found by sixty halvings, then three spiral segments joined (pg spring_line). */
CREATE MACRO m_spring_line(arbor_deg DOUBLE, wound DOUBLE) AS TABLE
WITH RECURSIVE s AS (SELECT * FROM movement.power_spec WHERE id = 1),
b AS (SELECT 0 AS i, 0.0::DOUBLE AS lo, (wound - free_turns)::DOUBLE AS hi FROM s),
r AS (
  SELECT i, lo, hi FROM b
  UNION ALL
  SELECT i+1,
    CASE WHEN m_spring_len((lo+hi)/2, (wound - free_turns) - (lo+hi)/2) > l THEN (lo+hi)/2 ELSE lo END,
    CASE WHEN m_spring_len((lo+hi)/2, (wound - free_turns) - (lo+hi)/2) > l THEN hi ELSE (lo+hi)/2 END
  FROM r, s WHERE i < 59),
n AS (SELECT hi AS n_in FROM r WHERE i = 59),
d AS (SELECT s.*, n.n_in, (wound - free_turns - n.n_in) AS n_out,
             ra + t/2 + t*n.n_in AS r1,
             rb - t/2 - t*(wound - free_turns - n.n_in) AS r2
      FROM s, n),
sp AS (
  SELECT 1 AS seg, j, pt FROM d, m_spiral_pts(d.ra + d.t/2, d.t, arbor_deg, d.n_in, -1, d.pts_per_turn) x(j, pt)
  UNION ALL
  SELECT 2, j, pt FROM d, m_spiral_pts(d.r1, (d.r2 - d.r1)/d.free_turns, arbor_deg - 360*d.n_in, d.free_turns, -1, d.pts_per_turn) x(j, pt) WHERE j > 0
  UNION ALL
  SELECT 3, j, pt FROM d, m_spiral_pts(d.r2, d.t, arbor_deg - 360*(d.n_in + d.free_turns), d.n_out, -1, d.pts_per_turn) x(j, pt) WHERE j > 0)
SELECT ST_MakeLine(list(pt ORDER BY seg, j)::GEOMETRY[]) AS g
FROM sp;
