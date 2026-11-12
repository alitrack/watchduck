/* =====================================================================
   The Watchmaker, Part 2  —  duckdb/03_calibre.sql
   DuckDB port of pg/03_calibre.sql. Every arbor, every part, every piece.

   Plan (seen from the dial, 26 mm): barrel ~11 o'clock, centre wheel in
   the middle, third wheel ~4:30, fourth wheel at 6 (carries the small
   seconds), then escape wheel, pallet fork, balance round to 9. Crown at 3.
   Mainplate z 0..1.2; behind (negative z) the train/barrel/bridges; front
   (z>1.2) the motion works, dial, hands. Units mm.
   ===================================================================== */

/* ---- settings ---- */
INSERT INTO movement.setting VALUES
    ('click_bearing', 210),
    ('hours', 10), ('minutes', 10), ('seconds', 30);

/* ---- arbors: bearings typed in, distances worked out ---- */
INSERT INTO movement.arbor (arbor, from_arbor, bearing) VALUES
    ('centre',  NULL,      NULL),
    ('barrel',  'centre',  100),
    ('third',   'centre',  -45),
    ('fourth',  'third',  -150),
    ('escape',  'fourth',  160),
    ('pallet',  'escape',  150),
    ('balance', 'pallet',  150),
    ('minute',  'centre', -135),
    ('hour',    'minute',   45);

INSERT INTO movement.mesh VALUES
    (1, 'barrel', 'Barrel',       'teeth',  80, 'centre', 'Centre arbor', 'pinion', 10, 0.14,  'driver', 4, 'wheel', 'leaf'),
    (2, 'centre', 'Centre arbor', 'wheel',  80, 'third',  'Third arbor',  'pinion', 10, 0.13,  'driver', 3, 'wheel', 'leaf'),
    (3, 'third',  'Third arbor',  'wheel',  75, 'fourth', 'Fourth arbor', 'pinion', 10, 0.11,  'driver', 2, 'wheel', 'leaf'),
    (4, 'fourth', 'Fourth arbor', 'wheel',  80, 'escape', 'Escape arbor', 'pinion',  8, 0.08,  'driver', 1, 'wheel', 'leaf'),
    (5, 'centre', 'Cannon pinion', 'pinion', 12, 'minute', 'Minute wheel', 'wheel', 36, 0.125, 'driven', 5, 'motion', 'motion'),
    (6, 'minute', 'Minute wheel', 'pinion', 10, 'hour',   'Hour wheel',   'wheel',  40, 0.12,  'driven', 6, 'motion', 'motion');

/* centre distance = sum of pitch radii */
UPDATE movement.arbor AS a
SET distance = m.module * (m.driver_teeth + m.driven_teeth) / 2.0
FROM movement.mesh AS m
WHERE (m.driver_arbor = a.from_arbor AND m.driven_arbor = a.arbor)
   OR (m.driven_arbor = a.from_arbor AND m.driver_arbor = a.arbor);

/* escapement's own geometry, scaled */
UPDATE movement.arbor SET distance = (SELECT scale * r / cos(radians(30)) FROM movement.esc_spec) WHERE arbor = 'pallet';
UPDATE movement.arbor SET distance = (SELECT scale * lever FROM movement.esc_spec) WHERE arbor = 'balance';

/* the click's pivot */
INSERT INTO movement.arbor (arbor, from_arbor, bearing, distance)
SELECT 'click', 'barrel', s.value, sqrt(p.pawl_x * p.pawl_x + p.pawl_y * p.pawl_y)
FROM movement.setting AS s, movement.power_spec AS p WHERE s.name = 'click_bearing';

/* walk the arbor tree out from the centre to get x, y */
WITH RECURSIVE pos AS (
    SELECT arbor, 0.0::DOUBLE AS x, 0.0::DOUBLE AS y FROM movement.arbor WHERE from_arbor IS NULL
    UNION ALL
    SELECT a.arbor, p.x + a.distance * cos(radians(a.bearing)), p.y + a.distance * sin(radians(a.bearing))
    FROM movement.arbor AS a JOIN pos AS p ON p.arbor = a.from_arbor)
UPDATE movement.arbor AS a SET x = pos.x, y = pos.y FROM pos WHERE pos.arbor = a.arbor;

/* ---- other places: bridge feet, screw holes, dial feet ---- */
INSERT INTO movement.spot (spot, from_arbor, bearing, distance) VALUES
    ('barrel foot 1', 'barrel',   30,    6.8),
    ('barrel foot 2', 'barrel',  160,    6.8),
    ('train foot 1',  'third',     0,    5.4),
    ('train foot 2',  'fourth', -100,    4.2),
    ('pallet foot',   'pallet',  195,    1.8),
    ('cock foot',     'balance', 120,    5.2),
    ('dial foot 1',   'centre',   36.87, 10.0),
    ('dial foot 2',   'centre', -143.13, 10.0);
UPDATE movement.spot AS s
SET x = a.x + s.distance * cos(radians(s.bearing)), y = a.y + s.distance * sin(radians(s.bearing))
FROM movement.arbor AS a WHERE a.arbor = s.from_arbor;

INSERT INTO movement.pivot VALUES
    ('centre', 0.12), ('barrel', 0.30), ('third', 0.10), ('fourth', 0.10),
    ('escape', 0.07), ('pallet', 0.07), ('balance', 0.05);

/* =====================================================================
   HELPERS
   ===================================================================== */
CREATE MACRO m_pt(which TEXT)
  AS (SELECT ST_MakePoint(x, y) FROM (
        SELECT x, y FROM movement.arbor WHERE arbor = which
        UNION ALL SELECT x, y FROM movement.spot WHERE spot = which) p);

CREATE MACRO m_disc(which TEXT, r DOUBLE, n INT) AS TABLE
  SELECT (SELECT g FROM m_circle(ST_X(m_pt(which)), ST_Y(m_pt(which)), r, n)) AS g;

CREATE MACRO m_jewel_hole(which TEXT)
  AS (SELECT r + 0.01 FROM movement.pivot WHERE arbor = which);

CREATE MACRO m_esc_turn()
  AS (SELECT bearing - 90 FROM movement.arbor WHERE arbor = 'pallet');

/* escapement units (about the wheel) placed in the watch */
CREATE MACRO m_esc_place(g GEOMETRY) AS TABLE
  SELECT ST_Translate(ST_Rotate(ST_Scale(g, scale, scale), radians(et)), ex, ey) AS g
  FROM movement.esc_spec, (SELECT m_esc_turn() AS et) e,
       (SELECT x AS ex, y AS ey FROM movement.arbor WHERE arbor = 'escape');

CREATE MACRO m_power_turn()
  AS (SELECT s.value - degrees(atan2(p.pawl_y, p.pawl_x)) FROM movement.setting s, movement.power_spec p WHERE s.name = 'click_bearing');

/* hands' angles for the time in setting (clockwise: negative). Table macro:
   returns one row per hand name. */
CREATE MACRO m_hand_deg(which TEXT) AS TABLE
SELECT CASE which WHEN 'hour'   THEN -30 * (h + mnt / 60 + s2 / 3600)
                  WHEN 'minute' THEN -6 * (mnt + s2 / 60)
                  ELSE -6 * s2 END AS deg
FROM (SELECT max(value) FILTER (WHERE name = 'hours') AS h,
             max(value) FILTER (WHERE name = 'minutes') AS mnt,
             max(value) FILTER (WHERE name = 'seconds') AS s2 FROM movement.setting) t;

/* a wheel's rim inside its tooth roots */
CREATE MACRO m_rim(z INT, m DOUBLE, kn TEXT)
  AS (SELECT m * z / 2.0 - fm.hf * m - 0.35 FROM movement.form fm WHERE fm.kind = kn);

/* bridge outlines (before their holes) */
CREATE MACRO m_cock_outline() AS TABLE
SELECT ST_Union(ST_Union((SELECT g FROM m_disc('balance', 1.6, 64)),
       ST_Buffer(ST_MakeLine([(SELECT m_pt('balance')), (SELECT m_pt('cock foot'))]::GEOMETRY[]), 0.9)),
       (SELECT g FROM m_disc('cock foot', 1.1, 48))) AS g;

CREATE MACRO m_train_bridge_outline() AS TABLE
WITH bands AS (
  SELECT ST_Buffer(ST_MakeLine([(SELECT m_pt('train foot 1')), (SELECT m_pt('third')), (SELECT m_pt('centre'))]::GEOMETRY[]), 0.75) AS g
  UNION ALL SELECT ST_Buffer(ST_MakeLine([(SELECT m_pt('third')), (SELECT m_pt('fourth')), (SELECT m_pt('train foot 2'))]::GEOMETRY[]), 0.75)
  UNION ALL SELECT ST_Buffer(ST_MakeLine([(SELECT m_pt('fourth')), (SELECT m_pt('escape'))]::GEOMETRY[]), 0.75)
  UNION ALL SELECT (SELECT g FROM m_disc('centre', 1.0, 48))
  UNION ALL SELECT (SELECT g FROM m_disc('third', 1.0, 48))
  UNION ALL SELECT (SELECT g FROM m_disc('fourth', 1.0, 48))
  UNION ALL SELECT (SELECT g FROM m_disc('escape', 1.0, 48))
  UNION ALL SELECT (SELECT g FROM m_disc('train foot 1', 1.0, 48))
  UNION ALL SELECT (SELECT g FROM m_disc('train foot 2', 1.0, 48)))
SELECT ST_Difference(ST_Union_Agg(bands.g), ST_Buffer((SELECT g FROM m_disc('barrel', 5.3, 128)), 0.15)) AS g
FROM bands;
