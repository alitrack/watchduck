/* =====================================================================
   The Watchmaker, Part 2  —  duckdb/01_schema.sql
   DuckDB port of pg/01_schema.sql. Same tables, same frame.
   Frame: x,y seen from the dial (12 o'clock +y, crown +x); z out of dial.
   Mainplate z 0..1.2. Behind (negative z): train, barrel, bridges.
   Front (z>1.2): motion works, dial, hands. Units mm.
   ===================================================================== */
INSTALL spatial;
LOAD spatial;

CREATE SCHEMA IF NOT EXISTS movement;

CREATE OR REPLACE TABLE movement.form (
    kind TEXT PRIMARY KEY,
    s DOUBLE NOT NULL,
    ha DOUBLE,
    hf DOUBLE NOT NULL,
    flank_pts INT,
    tip_step INT
);
INSERT INTO movement.form VALUES
    ('wheel',  1.50, 1.40, 1.60, 6, NULL),
    ('leaf',   1.20, NULL, 1.65, NULL, 20),
    ('motion', 1.40, 1.40, 1.65, 6, NULL);

CREATE OR REPLACE TABLE movement.esc_spec (
    id INT PRIMARY KEY,
    r DOUBLE, rr DOUBLE, teeth INT, club_rise DOUBLE, lever DOUBLE,
    rj DOUBLE, jewel_r DOUBLE, lock_deg DOUBLE, lift_deg DOUBLE, draw_deg DOUBLE,
    bank_deg DOUBLE, stone_w DOUBLE, entry_lock DOUBLE, exit_lock DOUBLE,
    scale DOUBLE,
    theta0 DOUBLE, phi0 DOUBLE, beta0 DOUBLE
);
INSERT INTO movement.esc_spec VALUES
    (1, 10.0, 7.2, 15, 0.20, 13.0, 3.0, 0.35, 1.0, 6.0, 12.0, 6.0, 7.0, 56.5, 116.5,
     0.22, 8.6, -6.0, 110.0);

CREATE OR REPLACE TABLE movement.arbor (
    arbor TEXT PRIMARY KEY,
    from_arbor TEXT,
    bearing DOUBLE,
    distance DOUBLE,
    x DOUBLE, y DOUBLE
);

CREATE OR REPLACE TABLE movement.spot (
    spot TEXT PRIMARY KEY,
    from_arbor TEXT NOT NULL,
    bearing DOUBLE NOT NULL,
    distance DOUBLE NOT NULL,
    x DOUBLE, y DOUBLE
);

CREATE OR REPLACE TABLE movement.pivot (
    arbor TEXT PRIMARY KEY,
    r DOUBLE NOT NULL
);

CREATE OR REPLACE TABLE movement.setting (
    name TEXT PRIMARY KEY,
    value DOUBLE NOT NULL
);

CREATE OR REPLACE TABLE movement.mesh (
    mesh_no INT PRIMARY KEY,
    driver_arbor TEXT NOT NULL, driver_part TEXT NOT NULL, driver_piece TEXT NOT NULL,
    driver_teeth INT NOT NULL,
    driven_arbor TEXT NOT NULL, driven_part TEXT NOT NULL, driven_piece TEXT NOT NULL,
    driven_teeth INT NOT NULL, module DOUBLE NOT NULL,
    moves TEXT NOT NULL, seq INT NOT NULL,
    driver_kind TEXT NOT NULL, driven_kind TEXT NOT NULL
);

CREATE OR REPLACE TABLE movement.part (
    part TEXT PRIMARY KEY,
    arbor TEXT,
    phase DOUBLE NOT NULL DEFAULT 0,
    axis TEXT NOT NULL DEFAULT 'z',
    is_base BOOLEAN NOT NULL DEFAULT false
);

CREATE OR REPLACE TABLE movement.piece (
    part TEXT NOT NULL,
    piece TEXT NOT NULL,
    material TEXT NOT NULL,
    profile GEOMETRY NOT NULL,
    z0 DOUBLE NOT NULL,
    z1 DOUBLE NOT NULL,
    PRIMARY KEY (part, piece)
);

CREATE OR REPLACE TABLE movement.removal (
    part TEXT PRIMARY KEY,
    round INT NOT NULL,
    dx DOUBLE NOT NULL,
    dy DOUBLE NOT NULL,
    dz DOUBLE NOT NULL,
    level INT
);
