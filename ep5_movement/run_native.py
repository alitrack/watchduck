"""The Watchmaker Ep5 — duckdb port: phase the train, then take it apart.

pg computes three things with plpgsql that duckdb has no equivalent for;
the driver does them in Python, every geometric test being plain SQL:

  * clear_phase(moving, fixed, teeth) — rotate `moving` about its arbor,
    a tooth at a time in 240 sub-steps, and find the middle of the
    longest run where it does NOT touch `fixed` (max backlash either
    way). This is what lets meshed gears sit clear of each other.
    The whole clear[] is one SQL over the v_piece view; Python only
    picks the longest run out of 240 booleans.
  * phase_meshes() — walk the mesh table in seq order and turn each
    mesh to clear its partner (the `moves` column picks which side).
  * phase_click() — lift the click until it clears the ratchet, drop
    to the top of that clear run.

Then the take_apart peeling: one blocking query per part per round,
exactly as pg's plpgsql loop did.
"""
import duckdb, re, time, sys, os

BASE = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
FILES = ["01_schema.sql", "02_profiles.sql", "03_calibre.sql", "03_calibre_b.sql", "04_take_apart.sql"]

# golden 8-round table (README.md). "third/fourth/centre/escape wheel"
# are the Third/Fourth/Centre/Escape *arbor* parts (the wheel is the
# arbor part's main piece, as in pg).
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

def statements(sql):
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    return [s.strip() for s in sql.split(";") if s.strip()]

def arbor_xy(con, part):
    r = con.execute("SELECT a.x, a.y FROM movement.part p LEFT JOIN movement.arbor a ON a.arbor = p.arbor WHERE p.part = ?", [part]).fetchone()
    return (r[0] or 0.0, r[1] or 0.0)

def clear_phase(con, moving_part, moving_piece, fixed_part, fixed_piece, teeth, steps=240):
    """middle of the longest clear run, in degrees; the pg algorithm."""
    cx, cy = arbor_xy(con, moving_part)
    # one SQL: for each sub-step j, is the moving piece (rotated about its
    # arbor by 360/teeth * j/steps degrees) clear of the fixed piece?
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
    # first blocked step (search 1..n), so runs don't wrap
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
        # rotate the click piece about its arbor by a degrees, test vs the ratchet
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
    return a

def take_apart(con):
    ways = con.execute("SELECT part, axis, is_base, s FROM movement.v_way_out").fetchall()
    allparts = {w[0] for w in ways}
    bases = {w[0] for w in ways if w[2]}
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
            else:
                bl = con.execute("SELECT blocker FROM m_blockers(?, ?)", [part, int(s)]).fetchall()
                print("    [round %d] %s (s=%d) blocked by: %s" % (r, part, s, [b[0] for b in bl]), flush=True)
        if not free:
            break
        for part, dx, dz in free:
            removal.append((part, r, dx, dz))
            con.execute("INSERT INTO movement.removal VALUES (?,?,?,?,?,NULL)", [part, r, dx, 0.0, dz])
    stuck = allparts - bases - {x[0] for x in removal}
    r = max((rd for _, rd, _, _ in removal), default=0)
    print("\n=== ROUNDS (peeled %d) ===" % r, flush=True)
    for rr in range(1, r + 1):
        back  = sorted(p for p, rd, dx, dz in removal if rd == rr and dz < 0)
        front = sorted(p for p, rd, dx, dz in removal if rd == rr and dz > 0)
        side  = sorted(p for p, rd, dx, dz in removal if rd == rr and dx > 0)
        print("round %d: back=%s front=%s side=%s" % (rr, back, front, side), flush=True)
    if stuck:
        print("\nSTUCK: %s" % sorted(stuck), flush=True)
    else:
        print("\nall %d non-base parts removed in %d rounds" % (len(allparts) - len(bases), r), flush=True)
    print("\n=== GOLDEN TABLE COMPARISON ===", flush=True)
    ok = True
    for rr in range(1, r + 1):
        back  = {p for p, rd, dx, dz in removal if rd == rr and dz < 0}
        front = {p for p, rd, dx, dz in removal if rd == rr and dz > 0}
        side  = {p for p, rd, dx, dz in removal if rd == rr and dx > 0}
        for label, got, want in [("back", back, GOLDEN_BACK.get(rr, set())),
                                 ("front", front, GOLDEN_FRONT.get(rr, set())),
                                 ("side", side, GOLDEN_SIDE.get(rr, set()))]:
            if got != want:
                ok = False
                print("  round %d %s: MISMATCH got=%s want=%s" % (rr, label, sorted(got), sorted(want)), flush=True)
    if ok:
        print("  GOLDEN MATCH — all 8 rounds identical to the pg version")

def main():
    con = duckdb.connect()
    con.execute("INSTALL spatial; LOAD spatial;")
    t0 = time.time()
    for f in FILES:
        for stmt in statements(open(BASE + "/sql/" + f).read()):
            con.execute(stmt)
    print("assembled in %.1fs" % (time.time() - t0), flush=True)
    phase_meshes(con)
    phase_click(con)
    take_apart(con)

if __name__ == "__main__":
    main()
