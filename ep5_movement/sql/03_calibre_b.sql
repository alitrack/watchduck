/* =====================================================================
   PARTS
   ===================================================================== */
CREATE TEMP TABLE parts_src AS
SELECT v.part, v.arbor, v.phase, v.axis, v.is_base
FROM (SELECT (SELECT m_esc_turn()) AS et, (SELECT m_power_turn()) AS pt, s.theta0, s.phi0, s.beta0,
             -30 * (10 + 10.0/60 + 30.0/3600) AS hd,
             -6 * (10 + 30.0/60) AS md,
             -6 * 30 AS sd
      FROM movement.esc_spec s) c,
LATERAL (VALUES
    ('Mainplate',              NULL::TEXT, 0.0::DOUBLE, 'z', true),
    ('Barrel bridge',          NULL, 0, 'z', false),
    ('Train bridge',           NULL, 0, 'z', false),
    ('Pallet bridge',          NULL, 0, 'z', false),
    ('Balance cock',           NULL, 0, 'z', false),
    ('Screw, barrel bridge 1', NULL, 0, 'z', false),
    ('Screw, barrel bridge 2', NULL, 0, 'z', false),
    ('Screw, train bridge 1',  NULL, 0, 'z', false),
    ('Screw, train bridge 2',  NULL, 0, 'z', false),
    ('Screw, pallet bridge',   NULL, 0, 'z', false),
    ('Screw, balance cock',    NULL, 0, 'z', false),
    ('Ratchet screw',          NULL, 0, 'z', false),
    ('Click screw',            NULL, 0, 'z', false),
    ('Ratchet',                'barrel',  c.pt, 'z', false),
    ('Click',                  'click',   c.pt, 'z', false),
    ('Barrel arbor',           'barrel',  c.pt, 'z', false),
    ('Barrel',                 'barrel',  0, 'z', false),
    ('Barrel cover',           'barrel',  0, 'z', false),
    ('Mainspring',             'barrel',  c.pt, 'z', false),
    ('Centre arbor',           'centre',  0, 'z', false),
    ('Third arbor',            'third',   0, 'z', false),
    ('Fourth arbor',           'fourth',  0, 'z', false),
    ('Escape arbor',           'escape',  c.et + c.theta0, 'z', false),
    ('Pallet fork',            'pallet',  c.et + c.phi0, 'z', false),
    ('Balance',                'balance', c.et + c.beta0, 'z', false),
    ('Hairspring',             'balance', c.et + c.beta0, 'z', false),
    ('Cannon pinion',          'centre',  0, 'z', false),
    ('Minute wheel',           'minute',  0, 'z', false),
    ('Hour wheel',             'hour',    0, 'z', false),
    ('Dial',                   NULL, 0, 'z', false),
    ('Hour hand',              'hour',    c.hd, 'z', false),
    ('Minute hand',            'centre',  c.md, 'z', false),
    ('Seconds hand',           'fourth',  c.sd, 'z', false),
    ('Stem',                   NULL, 0, 'x', false)
) AS v (part, arbor, phase, axis, is_base);
INSERT INTO movement.part SELECT * FROM parts_src;
DROP TABLE parts_src;

/* =====================================================================
   PIECES  (z0, z1 along the part's axis; behind the plate is negative)
   ===================================================================== */

/* ---- the mainplate ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
WITH holes AS (
  SELECT ST_Union_Agg(d.g) AS g FROM (
    SELECT (SELECT g FROM m_disc('third', 0.45, 32)) AS g
    UNION ALL SELECT (SELECT g FROM m_disc('fourth', 0.45, 32))
    UNION ALL SELECT (SELECT g FROM m_disc('escape', 0.45, 32))
    UNION ALL SELECT (SELECT g FROM m_disc('pallet', 0.45, 32))
    UNION ALL SELECT (SELECT g FROM m_disc('balance', 0.45, 32))
    UNION ALL SELECT (SELECT g FROM m_disc('centre', 0.27, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('barrel', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('barrel foot 1', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('barrel foot 2', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('train foot 1', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('train foot 2', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('pallet foot', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('cock foot', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('dial foot 1', 0.27, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('dial foot 2', 0.27, 24))) d),
plate AS (SELECT ST_Difference((SELECT g FROM m_circle(0,0,13.0,256)), holes.g) AS g FROM holes)
SELECT 'Mainplate', 'layer 1', 'plate', g, 0.0, 0.1 FROM plate
UNION ALL SELECT 'Mainplate', 'layer 2', 'plate', ST_Difference(g, ST_MakeEnvelope(8.95, -0.5, 13.5, 0.5)), 0.1, 1.1 FROM plate
UNION ALL SELECT 'Mainplate', 'layer 3', 'plate', g, 1.1, 1.2 FROM plate
UNION ALL
SELECT 'Mainplate', 'jewel, ' || a.arbor, 'ruby',
       (SELECT g FROM m_annulus(a.x, a.y, 0.45, (SELECT m_jewel_hole(a.arbor)), 32)), 0.0, 1.2
FROM movement.arbor a WHERE a.arbor IN ('third','fourth','escape','pallet','balance')
UNION ALL
SELECT 'Mainplate', 'banking pins', 'steel', (SELECT g FROM m_esc_place((SELECT g FROM m_banking_pins()))), -1.25, 0.0
UNION ALL
SELECT 'Mainplate', 'minute stud', 'steel', (SELECT g FROM m_disc('minute', 0.3, 32)), 1.2, 2.0;

/* ---- bridges ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
WITH c1 AS (
  SELECT ST_Union(
           ST_Union((SELECT g FROM m_disc('barrel', 6.0, 128)),
                    (SELECT g FROM m_disc('barrel foot 1', 1.0, 48))),
           ST_Union((SELECT g FROM m_disc('barrel foot 2', 1.0, 48)),
                    (SELECT g FROM m_disc('click', 1.0, 48)))) AS g),
bbo AS (
  SELECT ST_Intersection(ST_ConvexHull(c1.g), (SELECT g FROM m_circle(0,0,12.9,256))) AS g FROM c1),
bho AS (
  SELECT ST_Union_Agg(x.g) AS g FROM (
    SELECT (SELECT g FROM m_disc('barrel', 0.62, 32)) AS g
    UNION ALL SELECT (SELECT g FROM m_disc('barrel foot 1', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('barrel foot 2', 0.32, 24))
    UNION ALL SELECT (SELECT g FROM m_disc('click', 0.18, 16))
    UNION ALL SELECT ST_Buffer((SELECT g FROM m_cock_outline()), 0.25)) x)
SELECT 'Barrel bridge', 'plate', 'plate', ST_Difference(bbo.g, bho.g), -3.40, -2.90 FROM bbo, bho
UNION ALL
SELECT 'Barrel bridge', 'foot ' || k, 'plate',
       ST_Difference((SELECT g FROM m_disc('barrel foot ' || k, 0.8, 48)), (SELECT g FROM m_disc('barrel foot ' || k, 0.32, 24))),
       -2.90, 0.0 FROM range(1,3) x(k)
UNION ALL
SELECT 'Train bridge', 'plate', 'plate', t.diff, -2.20, -1.70 FROM (
       SELECT ST_Difference((SELECT g FROM m_train_bridge_outline()), t2.holes) AS diff
       FROM (SELECT ST_Union_Agg(y.g) AS holes FROM (
           SELECT (SELECT g FROM m_disc('centre', 0.13, 16)) AS g
           UNION ALL SELECT (SELECT g FROM m_disc('third', 0.45, 32))
           UNION ALL SELECT (SELECT g FROM m_disc('fourth', 0.45, 32))
           UNION ALL SELECT (SELECT g FROM m_disc('escape', 0.45, 32))
           UNION ALL SELECT (SELECT g FROM m_disc('train foot 1', 0.32, 24))
           UNION ALL SELECT (SELECT g FROM m_disc('train foot 2', 0.32, 24))) y) t2) t
UNION ALL
SELECT 'Train bridge', 'jewel, ' || a.arbor, 'ruby',
       (SELECT g FROM m_annulus(a.x, a.y, 0.45, (SELECT m_jewel_hole(a.arbor)), 32)), -2.20, -1.70
FROM movement.arbor a WHERE a.arbor IN ('third','fourth','escape')
UNION ALL
SELECT 'Train bridge', 'foot ' || k, 'plate',
       ST_Difference((SELECT g FROM m_disc('train foot ' || k, 0.8, 48)), (SELECT g FROM m_disc('train foot ' || k, 0.32, 24))),
       -1.70, 0.0 FROM range(1,3) x(k)
UNION ALL
SELECT 'Pallet bridge', 'plate', 'plate',
       ST_Difference(
         ST_Union(ST_Buffer(ST_MakeLine([m_pt('pallet'), m_pt('pallet foot')]::GEOMETRY[]), 0.6),
                  ST_Union((SELECT g FROM m_disc('pallet', 0.9, 48)), (SELECT g FROM m_disc('pallet foot', 1.0, 48)))),
         ST_Union((SELECT g FROM m_disc('pallet', 0.45, 32)), (SELECT g FROM m_disc('pallet foot', 0.32, 24)))),
       -2.00, -1.70
UNION ALL
SELECT 'Pallet bridge', 'jewel', 'ruby',
       (SELECT g FROM m_annulus((SELECT x FROM movement.arbor WHERE arbor='pallet'), (SELECT y FROM movement.arbor WHERE arbor='pallet'), 0.45, (SELECT m_jewel_hole('pallet')), 32)),
       -2.00, -1.70
UNION ALL
SELECT 'Pallet bridge', 'foot', 'plate',
       ST_Difference((SELECT g FROM m_disc('pallet foot', 0.8, 48)), (SELECT g FROM m_disc('pallet foot', 0.32, 24))),
       -1.70, 0.0
UNION ALL
SELECT 'Balance cock', 'plate', 'plate',
       ST_Difference((SELECT g FROM m_cock_outline()),
         ST_Union((SELECT g FROM m_disc('balance', 0.45, 32)), (SELECT g FROM m_disc('cock foot', 0.32, 24)))),
       -3.60, -3.10
UNION ALL
SELECT 'Balance cock', 'jewel', 'ruby',
       (SELECT g FROM m_annulus((SELECT x FROM movement.arbor WHERE arbor='balance'), (SELECT y FROM movement.arbor WHERE arbor='balance'), 0.45, (SELECT m_jewel_hole('balance')), 32)),
       -3.60, -3.10
UNION ALL
SELECT 'Balance cock', 'foot', 'plate',
       ST_Difference((SELECT g FROM m_disc('cock foot', 0.9, 48)), (SELECT g FROM m_disc('cock foot', 0.32, 24))),
       -3.10, 0.0;

/* ---- screws ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT s.part, 'head', 'blued', (SELECT g FROM m_disc(s.spot, 0.55, 32)), s.top - 0.25, s.top
FROM (VALUES ('Screw, barrel bridge 1','barrel foot 1',-3.40),('Screw, barrel bridge 2','barrel foot 2',-3.40),
             ('Screw, train bridge 1','train foot 1',-2.20),('Screw, train bridge 2','train foot 2',-2.20),
             ('Screw, pallet bridge','pallet foot',-2.00),('Screw, balance cock','cock foot',-3.60)) s(part, spot, top)
UNION ALL
SELECT s.part, 'shank', 'blued', (SELECT g FROM m_disc(s.spot, 0.30, 24)), s.top, 0.8
FROM (VALUES ('Screw, barrel bridge 1','barrel foot 1',-3.40),('Screw, barrel bridge 2','barrel foot 2',-3.40),
             ('Screw, train bridge 1','train foot 1',-2.20),('Screw, train bridge 2','train foot 2',-2.20),
             ('Screw, pallet bridge','pallet foot',-2.00),('Screw, balance cock','cock foot',-3.60)) s(part, spot, top)
UNION ALL
SELECT 'Ratchet screw', 'head',  'blued', (SELECT g FROM m_disc('barrel', 1.2, 48)), -4.00, -3.75
UNION ALL
SELECT 'Ratchet screw', 'shank', 'blued', (SELECT g FROM m_disc('barrel', 0.35, 24)), -3.75, -3.45
UNION ALL
SELECT 'Click screw',   'head',  'blued', (SELECT g FROM m_disc('click', 0.5, 32)), -3.95, -3.75
UNION ALL
SELECT 'Click screw',   'shank', 'blued', (SELECT g FROM m_disc('click', 0.17, 16)), -3.75, -3.10;

/* ---- power ---- */
CREATE TABLE movement.spring_limits AS SELECT * FROM m_spring_limits();

INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Ratchet', 'wheel', 'steel', ST_Difference((SELECT g FROM m_ratchet()), ST_MakeEnvelope(-0.4, -0.4, 0.4, 0.4)), -3.75, -3.45
UNION ALL
SELECT 'Click', 'click', 'steel', ST_Translate((SELECT g FROM m_click()), -p.pawl_x, -p.pawl_y), -3.75, -3.45
FROM movement.power_spec p
UNION ALL
SELECT 'Barrel arbor', 'lower pivot', 'steel', (SELECT g FROM m_circle(0,0,0.30,24)), -0.05, 0.9
UNION ALL
SELECT 'Barrel arbor', 'shaft 1', 'steel', (SELECT g FROM m_circle(0,0,0.60,32)), -0.75, -0.05
UNION ALL
SELECT 'Barrel arbor', 'core', 'steel', (SELECT g FROM m_circle(0,0,1.60,64)), -2.50, -0.75
UNION ALL
SELECT 'Barrel arbor', 'shaft 2', 'steel', (SELECT g FROM m_circle(0,0,0.60,32)), -3.40, -2.50
UNION ALL
SELECT 'Barrel arbor', 'square', 'steel',
       ST_Difference(ST_MakeEnvelope(-0.4, -0.4, 0.4, 0.4), (SELECT g FROM m_circle(0,0,0.36,24))), -3.75, -3.40
UNION ALL
SELECT 'Barrel', 'teeth', 'gilt', ST_Difference((SELECT g FROM m_gear(80, 0.14, 0.35, 'wheel')), (SELECT g FROM m_circle(0,0,5.0,128))), -0.95, -0.55
UNION ALL
SELECT 'Barrel', 'floor', 'gilt', (SELECT g FROM m_annulus(0,0,5.0,0.62,128)), -0.70, -0.55
UNION ALL
SELECT 'Barrel', 'wall', 'gilt', (SELECT g FROM m_annulus(0,0,5.3,5.0,128)), -2.55, -0.95
UNION ALL
SELECT 'Barrel cover', 'cover', 'gilt', (SELECT g FROM m_annulus(0,0,5.3,0.62,128)), -2.70, -2.55
UNION ALL
SELECT 'Mainspring', 'spring', 'spring',
       ST_Buffer((SELECT g FROM m_spring_line(0.0, ms.mid)), 0.045, 2), -2.45, -0.80
FROM (SELECT (let_down + wound) / 2.0 AS mid FROM movement.spring_limits) ms;

/* ---- the going train ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Centre arbor', 'dial shaft', 'steel', (SELECT g FROM m_circle(0,0,0.25,24)), -0.05, 2.60
UNION ALL
SELECT 'Centre arbor', 'shaft', 'steel', (SELECT g FROM m_circle(0,0,0.30,24)), -1.65, -0.05
UNION ALL
SELECT 'Centre arbor', 'wheel', 'gilt',
       (SELECT g FROM m_crossed((SELECT g FROM m_gear(80, 0.13, 0.325, 'wheel')),
                                 (SELECT m_rim(80, 0.13, 'wheel')), 0.55, 0.30, 4, 0.17, 45.0)),
       -0.30, -0.15
UNION ALL
SELECT 'Centre arbor', 'pinion', 'steel', (SELECT g FROM m_pinion(10, 0.14)), -1.05, -0.45
UNION ALL
SELECT 'Centre arbor', 'pivot', 'steel', (SELECT g FROM m_circle(0,0,0.12,16)), -2.15, -1.65
UNION ALL
SELECT 'Third arbor', 'lower pivot', 'steel', (SELECT g FROM m_circle(0,0,0.10,16)), -0.05, 0.9
UNION ALL
SELECT 'Third arbor', 'pinion', 'steel', (SELECT g FROM m_pinion(10, 0.13)), -0.40, -0.05
UNION ALL
SELECT 'Third arbor', 'shaft', 'steel', (SELECT g FROM m_circle(0,0,0.25,24)), -1.65, -0.40
UNION ALL
SELECT 'Third arbor', 'wheel', 'gilt',
       (SELECT g FROM m_crossed((SELECT g FROM m_gear(75, 0.11, 0.275, 'wheel')),
                                 (SELECT m_rim(75, 0.11, 'wheel')), 0.55, 0.25, 4, 0.17, 45.0)),
       -1.25, -1.10
UNION ALL
SELECT 'Third arbor', 'pivot', 'steel', (SELECT g FROM m_circle(0,0,0.10,16)), -2.15, -1.65
UNION ALL
SELECT 'Fourth arbor', 'seconds pivot', 'steel', (SELECT g FROM m_circle(0,0,0.10,16)), -0.05, 2.70
UNION ALL
SELECT 'Fourth arbor', 'shaft', 'steel', (SELECT g FROM m_circle(0,0,0.25,24)), -1.65, -0.05
UNION ALL
SELECT 'Fourth arbor', 'wheel', 'gilt',
       (SELECT g FROM m_crossed((SELECT g FROM m_gear(80, 0.08, 0.16, 'wheel')),
                                 (SELECT m_rim(80, 0.08, 'wheel')), 0.50, 0.25, 4, 0.15, 45.0)),
       -0.68, -0.55
UNION ALL
SELECT 'Fourth arbor', 'pinion', 'steel', (SELECT g FROM m_pinion(10, 0.11)), -1.35, -1.00
UNION ALL
SELECT 'Fourth arbor', 'pivot', 'steel', (SELECT g FROM m_circle(0,0,0.10,16)), -2.15, -1.65
UNION ALL
SELECT 'Escape arbor', 'lower pivot', 'steel', (SELECT g FROM m_circle(0,0,0.07,16)), -0.05, 0.9
UNION ALL
SELECT 'Escape arbor', 'shaft', 'steel', (SELECT g FROM m_circle(0,0,0.20,24)), -1.65, -0.05
UNION ALL
SELECT 'Escape arbor', 'pinion', 'steel', (SELECT g FROM m_pinion(8, 0.08)), -0.78, -0.45
UNION ALL
SELECT 'Escape arbor', 'wheel', 'steel', ST_Scale((SELECT g FROM m_escape_wheel_display()), scale, scale), -1.22, -1.10
FROM movement.esc_spec
UNION ALL
SELECT 'Escape arbor', 'pivot', 'steel', (SELECT g FROM m_circle(0,0,0.07,16)), -2.15, -1.65;

/* ---- escapement: fork and roller, scaled; new balance wheel and hairspring ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Pallet fork', 'lower pivot', 'steel', (SELECT g FROM m_circle(0,0,0.07,16)), -0.05, 0.9
UNION ALL
SELECT 'Pallet fork', 'staff', 'steel', (SELECT g FROM m_circle(0,0,0.15,24)), -1.65, -0.05
UNION ALL
SELECT 'Pallet fork', 'fork', 'steel',
       ST_Scale(ST_Translate(ST_Union((SELECT g FROM m_lever()), (SELECT g FROM m_pallet_body())), 0, -ST_Y(m_esc_p())), scale, scale),
       -1.22, -1.10 FROM movement.esc_spec
UNION ALL
SELECT 'Pallet fork', v.piece, 'ruby',
       ST_Scale(ST_Translate((SELECT g FROM m_stone(v.lock_at)), 0, -ST_Y(m_esc_p())), scale, scale), -1.22, -1.10
FROM movement.esc_spec, (VALUES ('entry stone', entry_lock), ('exit stone', exit_lock)) v(piece, lock_at)
UNION ALL
SELECT 'Pallet fork', 'pivot', 'steel', (SELECT g FROM m_circle(0,0,0.07,16)), -1.95, -1.65
UNION ALL
SELECT 'Balance', 'lower pivot', 'steel', (SELECT g FROM m_circle(0,0,0.05,12)), -0.05, 0.9
UNION ALL
SELECT 'Balance', 'staff 1', 'steel', (SELECT g FROM m_circle(0,0,0.15,24)), -1.45, -0.05
UNION ALL
SELECT 'Balance', 'roller', 'steel', (SELECT g FROM m_circle(0,0,2.0 * scale, 48)), -1.55, -1.45 FROM movement.esc_spec
UNION ALL
SELECT 'Balance', 'impulse jewel', 'ruby', (SELECT g FROM m_circle(0, -rj * scale, jewel_r * scale, 24)), -1.55, -1.06 FROM movement.esc_spec
UNION ALL
SELECT 'Balance', 'staff 2', 'steel', (SELECT g FROM m_circle(0,0,0.25,24)), -2.30, -1.55
UNION ALL
SELECT 'Balance', 'wheel', 'gilt',
       (SELECT ST_Difference(big.g, (SELECT g FROM m_circle(0,0,0.25,24))) FROM (
         SELECT ST_Union_Agg(x.g) AS g FROM (
           SELECT (SELECT g FROM m_annulus(0,0,4.0,3.7,160)) AS g
           UNION ALL SELECT ST_Buffer(ST_MakeLine([ST_MakePoint(0,0), m_polar(3.8, -90 + 120*k, 0,0)]::GEOMETRY[]), 0.15, 4) FROM range(3) x(k)
           UNION ALL SELECT (SELECT g FROM m_circle(0,0,0.5,32))
           UNION ALL SELECT (SELECT g FROM m_circle(ST_X(m_polar(4.1, 15 + 30*k, 0,0)), ST_Y(m_polar(4.1, 15 + 30*k, 0,0)), 0.15, 12)) FROM range(12) x(k)) x) big),
       -2.60, -2.30
UNION ALL
SELECT 'Balance', 'staff 3', 'steel', (SELECT g FROM m_circle(0,0,0.25,24)), -2.75, -2.60
UNION ALL
SELECT 'Balance', 'staff 4', 'steel', (SELECT g FROM m_circle(0,0,0.15,32)), -3.05, -2.75
UNION ALL
SELECT 'Balance', 'pivot', 'steel', (SELECT g FROM m_circle(0,0,0.05,12)), -3.45, -3.05
UNION ALL
SELECT 'Hairspring', 'collet', 'steel', (SELECT g FROM m_annulus(0,0,0.40,0.15,32)), -2.87, -2.75
UNION ALL
SELECT 'Hairspring', 'spring', 'spring',
       ST_Buffer((SELECT g FROM m_hairspring_line(0, 24)), 0.018, 2), -2.87, -2.75;

/* ---- motion works, dial, hands, stem ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Cannon pinion', 'pinion', 'steel', ST_Difference((SELECT g FROM m_gear(12, 0.125, 1.125, 'motion')), (SELECT g FROM m_circle(0,0,0.26,24))), 1.30, 1.60
UNION ALL
SELECT 'Cannon pinion', 'pipe', 'steel', (SELECT g FROM m_annulus(0,0,0.45,0.26,32)), 1.60, 2.95
UNION ALL
SELECT 'Minute wheel', 'wheel', 'gilt',
       (SELECT g FROM m_crossed((SELECT g FROM m_gear(36, 0.125, 0.375, 'motion')),
                                 (SELECT m_rim(36, 0.125, 'motion')) + 0.05, 0.6, 0.32, 4, 0.15, 45.0)),
       1.35, 1.50
UNION ALL
SELECT 'Minute wheel', 'hub', 'gilt', (SELECT g FROM m_annulus(0,0,0.6,0.32,32)), 1.50, 1.62
UNION ALL
SELECT 'Minute wheel', 'pinion', 'steel', ST_Difference((SELECT g FROM m_gear(10, 0.12, 1.2, 'motion')), (SELECT g FROM m_circle(0,0,0.32,24))), 1.62, 1.92
UNION ALL
SELECT 'Hour wheel', 'wheel', 'gilt',
       (SELECT g FROM m_crossed((SELECT g FROM m_gear(40, 0.12, 0.3, 'motion')),
                                 (SELECT m_rim(40, 0.12, 'motion')) + 0.05, 0.8, 0.47, 4, 0.15, 45.0)),
       1.70, 1.85
UNION ALL
SELECT 'Hour wheel', 'pipe', 'gilt', (SELECT g FROM m_annulus(0,0,0.62,0.47,32)), 1.85, 2.75
UNION ALL
SELECT 'Dial', 'dial', 'dial',
       ST_Difference((SELECT g FROM m_circle(0,0,12.9,256)),
         ST_Union((SELECT g FROM m_circle(0,0,0.75,48)), (SELECT g FROM m_disc('fourth', 0.3, 24)))),
       2.40, 2.60
UNION ALL
SELECT 'Dial', 'feet', 'gilt', ST_Union((SELECT g FROM m_disc('dial foot 1', 0.25, 24)), (SELECT g FROM m_disc('dial foot 2', 0.25, 24))), 0.60, 2.40
UNION ALL
SELECT 'Dial', 'markers', 'gilt',
       (SELECT ST_Union_Agg(ST_Rotate(ST_MakeEnvelope(-0.25, 10.6, 0.25, 12.0), radians(-30 * k))) FROM range(12) x(k)),
       2.60, 2.68
UNION ALL
SELECT 'Dial', 'seconds ring', 'gilt',
       ST_Difference((SELECT g FROM m_disc('fourth', 2.0, 96)), (SELECT g FROM m_disc('fourth', 1.9, 96))), 2.60, 2.62
UNION ALL
SELECT 'Hour hand', 'hand', 'blued', (SELECT g FROM m_hand(1.2, 0.32, 5.4, 0.8, 0.90, 0.630, 32)), 2.68, 2.73
UNION ALL
SELECT 'Minute hand', 'hand', 'blued', (SELECT g FROM m_hand(1.4, 0.22, 8.6, 0.7, 0.65, 0.455, 32)), 2.88, 2.93
UNION ALL
SELECT 'Seconds hand', 'hand', 'blued', (SELECT g FROM m_hand(0.6, 0.07, 1.6, 0.3, 0.22, 0.103, 16)), 2.62, 2.66
UNION ALL
SELECT 'Stem', 'stem', 'steel', (SELECT g FROM m_circle(0, 0.6, 0.45, 32)), 9.0, 13.7
UNION ALL
SELECT 'Stem', 'tube', 'steel', (SELECT g FROM m_circle(0, 0.6, 0.90, 32)), 13.7, 14.1
UNION ALL
SELECT 'Stem', 'crown', 'gilt', (SELECT g FROM m_knurl(0, 0.6, 1.8, 1.65, 24)), 14.1, 15.9;

/* =====================================================================
   PLACING: world = the profile turned to its phase and moved to its
   arbor. A view, so it tracks phase updates from the phase driver.
   axis 'z': the profile is in the x y plane, about the arbor.
   axis 'x' (the stem): the profile is already built in the y z plane
   (its first coordinate is watch_y, second watch_z); it sits in place.
   ===================================================================== */
CREATE OR REPLACE VIEW movement.v_piece AS
SELECT pc.part, pc.piece, pc.z0, pc.z1,
       CASE WHEN p.axis = 'x' OR p.arbor IS NULL THEN pc.profile
            ELSE ST_Translate(ST_Rotate(pc.profile, radians(p.phase)), a.x, a.y)
       END AS world
FROM movement.piece pc
JOIN movement.part p ON p.part = pc.part
LEFT JOIN movement.arbor a ON a.arbor = p.arbor;
