"""Build the wasm snapshot: assemble the 34-part movement natively, solve all
phases (the verified pipeline — code copied verbatim from take_apart_driver2.py),
then dump the ASSEMBLED state as static data.

The wasm page loads this snapshot (world WKT per piece) and runs 04's
m_blocked take-apart loop live in the browser. Phases are baked into the
world geometry, so the page needs none of the 02/03 macro machinery.
"""
import duckdb, re, json, sys, os

BASE = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
FILES = ["01_schema.sql", "02_profiles.sql", "03_calibre.sql", "03_calibre_b.sql", "04_take_apart.sql"]
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(BASE, "movement_snapshot.json")

def statements(sql):
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    return [s.strip() for s in sql.split(";") if s.strip()]

def load(con):
    for f in FILES:
        p = os.path.join(BASE, "sql", f) if os.path.exists(os.path.join(BASE, "sql", f)) else os.path.join(BASE, f)
        for stmt in statements(open(p).read()):
            con.execute(stmt)

# ---------- verified phase code (take_apart_driver2.py verbatim) ----------
def arbor_xy(con, part):
    r = con.execute("SELECT a.x, a.y FROM movement.part p LEFT JOIN movement.arbor a ON a.arbor = p.arbor WHERE p.part = ?", [part]).fetchone()
    return (r[0] or 0.0, r[1] or 0.0)

def clear_phase(con, moving_part, moving_piece, fixed_part, fixed_piece, teeth, steps=240):
    cx, cy = arbor_xy(con, moving_part)
    q = (
      "SELECT j, NOT ST_Intersects("
      "  ST_Translate(ST_Rotate(ST_Translate(world, -cx, -cy), radians(360.0 / ? * j / ?)), cx, cy),"
      "  fixed) AS clear"
      " FROM (SELECT world, ? AS cx, ? AS cy FROM movement.v_piece WHERE part = ? AND piece = ?) mv,"
      "      (SELECT world AS fixed FROM movement.v_piece WHERE part = ? AND piece = ?),"
      "      range(0, ?) x(j)"
    )
    rows = con.execute(q, [teeth, steps, cx, cy, moving_part, moving_piece,
                           fixed_part, fixed_piece, steps]).fetchall()
    clear = [bool(r[1]) for r in rows]
    n = steps
    start_at = None
    for j in range(1, n + 1):
        if not clear[j - 1]:
            start_at = j
            break
    if start_at is None:
        return 0.0
    best, best_mid = 0, None
    run = 0
    for k in range(1, n + 1):
        idx = (start_at + k - 1) % n + 1
        if clear[idx - 1]:
            run += 1
            if run > best:
                best = run
                best_mid = start_at + k - (run - 1) / 2.0 - 1
        else:
            run = 0
    if best == 0:
        raise RuntimeError("%s never clears %s" % (moving_part, fixed_part))
    return 360.0 / teeth * best_mid / steps

def set_phase(con, part, delta):
    con.execute("UPDATE movement.part SET phase = phase + ? WHERE part = ?", [delta, part])

def phase_meshes(con):
    print("=== phase_meshes (gears to max-backlash position) ===", flush=True)
    for r in con.execute("SELECT mesh_no, driver_part, driver_piece, driven_part, driven_piece, driver_teeth, driven_teeth, moves FROM movement.mesh ORDER BY seq").fetchall():
        mesh_no, dpart, dpiece, fpart, fpiece, dteeth, fteeth, moves = r
        if moves == 'driver':
            d = clear_phase(con, dpart, dpiece, fpart, fpiece, dteeth)
            set_phase(con, dpart, d)
            who = dpart
        else:
            d = clear_phase(con, fpart, fpiece, dpart, dpiece, fteeth)
            set_phase(con, fpart, d)
            who = fpart
        print("  mesh %d: turned %-16s by %+.3f deg" % (mesh_no, who, d), flush=True)

def phase_click(con):
    print("=== phase_click (click to top of its clear run) ===", flush=True)
    cx, cy = arbor_xy(con, 'Click')
    def touches_at(a):
        r = con.execute(
            "SELECT ST_Intersects(ST_Translate(ST_Rotate(ST_Translate("
            " (SELECT world FROM movement.v_piece WHERE part = 'Click' AND piece = 'click'), -?, -?), radians(?)), ?, ?),"
            " (SELECT world FROM movement.v_piece WHERE part = 'Ratchet' AND piece = 'wheel'))",
            [cx, cy, a, cx, cy]).fetchone()[0]
        return bool(r)
    a = 0.0
    while a > -14 and touches_at(a):
        a -= 0.05
    while a < 4 and not touches_at(a + 0.05):
        a += 0.05
    set_phase(con, 'Click', a)
    print("  click turned by %+.2f deg" % a, flush=True)

def take_apart(con):
    ways = con.execute("SELECT part, axis, is_base, s FROM movement.v_way_out").fetchall()
    con.execute("DELETE FROM movement.removal")
    removal = []
    r = 0
    while True:
        r += 1
        free = []
        for part, axis, is_base, s in ways:
            if is_base or part in {x[0] for x in removal}:
                continue
            dx = s if axis == 'x' else 0
            dz = s if axis == 'z' else 0
            hit = con.execute("SELECT blocked FROM m_blocked(?, ?)", [part, int(s)]).fetchone()
            if not hit or not hit[0]:
                free.append((part, float(dx), float(dz)))
        if not free:
            break
        for part, dx, dz in free:
            removal.append((part, r, dx, 0.0, dz))
            con.execute("INSERT INTO movement.removal VALUES (?,?,?,?,?,NULL)", [part, r, dx, 0.0, dz])
    print("  peeled %d rounds, %d parts" % (max(rd for _, rd, *_ in removal), len(removal)), flush=True)
    return removal

# ---------- golden-table check (same tables as the driver) ----------
GOLDEN_BACK = {1:{"Screw, barrel bridge 1","Screw, barrel bridge 2","Screw, train bridge 1","Screw, train bridge 2","Screw, balance cock","Ratchet screw","Click screw"},
               2:{"Balance cock","Click","Ratchet"},
               3:{"Barrel bridge","Hairspring"},
               4:{"Balance","Barrel cover","Screw, pallet bridge","Train bridge"},
               5:{"Barrel arbor","Mainspring","Pallet bridge","Third arbor"},
               6:{"Barrel","Escape arbor","Pallet fork"},
               7:{"Fourth arbor"},
               8:{"Centre arbor"}}
GOLDEN_FRONT = {1:{"Minute hand","Seconds hand"}, 2:{"Hour hand"}, 3:{"Dial"},
                4:{"Hour wheel"}, 5:{"Cannon pinion","Minute wheel"}}
GOLDEN_SIDE = {1:{"Stem"}}

def check_golden(removal):
    ok = True
    for rr in range(1, 9):
        back  = {p for p, rd, dx, dy, dz in removal if rd == rr and dz < 0}
        front = {p for p, rd, dx, dy, dz in removal if rd == rr and dz > 0}
        side  = {p for p, rd, dx, dy, dz in removal if rd == rr and dx > 0}
        for label, got, want in [("back", back, GOLDEN_BACK.get(rr, set())),
                                 ("front", front, GOLDEN_FRONT.get(rr, set())),
                                 ("side", side, GOLDEN_SIDE.get(rr, set()))]:
            if got != want:
                ok = False
                print("  round %d %s MISMATCH got=%s want=%s" % (rr, label, sorted(got), sorted(want)), flush=True)
    print("  GOLDEN MATCH" if ok else "  GOLDEN MISMATCH — do not ship", flush=True)
    return ok

def main():
    con = duckdb.connect()
    con.execute("INSTALL spatial; LOAD spatial;")
    load(con)
    print("assembled:", con.execute("SELECT count(*) FROM movement.piece").fetchone()[0], "pieces", flush=True)
    phase_meshes(con)
    phase_click(con)
    removal = take_apart(con)
    if not check_golden(removal):
        raise SystemExit("golden table mismatch, aborting snapshot")

    parts = con.execute("SELECT part, axis, is_base FROM movement.part ORDER BY part").fetchall()
    pieces = []
    for part, pc, mat, wkt, z0, z1 in con.execute("""
        SELECT p.part, p.piece, p.material, ST_AsText(v.world), v.z0, v.z1
        FROM movement.v_piece v JOIN movement.piece p ON p.part = v.part AND p.piece = v.piece
        ORDER BY p.part, p.piece""").fetchall():
        pieces.append({"part": part, "piece": pc, "material": mat, "wkt": wkt, "z0": float(z0), "z1": float(z1)})
    stem = con.execute("SELECT pc, x0, x1, r FROM movement.stem_solid").fetchall()
    ways = con.execute("SELECT part, axis, is_base, s FROM movement.v_way_out ORDER BY part").fetchall()
    snap = {
        "version": 1,
        "source": "watchmaker-sql Ep5 pg -> duckdb port (alitrack/watchduck ep5_movement)",
        "parts": [{"part": p, "axis": ax, "is_base": bool(b)} for p, ax, b in parts],
        "way_out": [{"part": p, "axis": ax, "is_base": bool(b), "s": int(s)} for p, ax, b, s in ways],
        "pieces": pieces,
        "stem_solid": [{"pc": a, "x0": float(b), "x1": float(c), "r": float(d)} for a, b, c, d in stem],
        "take_apart_golden": [{"part": p, "round": rd, "dx": dx, "dy": dy, "dz": dz} for p, rd, dx, dy, dz in removal],
    }
    with open(OUT, "w") as f:
        json.dump(snap, f, separators=(",", ":"))
    print("snapshot written: %s (%.1f KB, %d pieces)" % (OUT, os.path.getsize(OUT) / 1024, len(pieces)), flush=True)

if __name__ == "__main__":
    main()
