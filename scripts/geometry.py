#!/usr/bin/env python3
"""Frozen escapement geometry for watchduck + the random search that found it.

Philosophy (after "The Watchmaker", sqlartist.github.io): model the metal, not
the maths. These polygons were found by random search against three purely
GEOMETRIC acceptance criteria - nothing here encodes "12 degrees per beat":

  1. LOCK:     fork centered (0 deg) -> wheel heavily blocked (>=35% of phases)
  2. RELEASE:  fork at +/-10 deg    -> free wheel travel ~= half a tooth pitch
  3. NO DEAD ZONES: for every wheel phase, SOME fork angle frees the wheel

The "half a tooth pitch per beat" (12 deg for a 15-tooth wheel) then falls out
of the shapes at runtime, inside DuckDB, when the solver walks the map.

Run:  python3 geometry.py            # prints acceptance stats
      python3 geometry.py --search   # reruns the random search
"""
import math, random, sys

# --- frozen result of the search (trial 1291, seed 42) ---
R = 10.0                 # escape wheel pitch radius (mm-ish units)
N_TEETH = 15
PITCH = 360.0 / N_TEETH  # 24 deg
TOOTH = [(-0.9, -0.55), (0.75, -0.35), (0.45, 0.85), (-0.9, 0.55)]  # local frame
PIVOT = (0.0, 13.906841355503715)   # pallet fork pivot, above wheel center
SL, SW = 4.172168276032077, 0.9435838419903526      # stone length / width
ENTRY = (-3.698835219030193, -1.92158763948672)    # entry stone center (fork frame)
EXIT  = (3.7889791082288786, -2.3478770420636748)  # exit stone center (fork frame)
# dynamics knobs (not geometry, but frozen with it)
A = 10.0          # fork swing amplitude (deg)
BEAT_HZ = 5.0     # 18000 beats/hour like a classic movement
W_SPEED = 160.0   # wheel deg/sec while free (release is nearly instantaneous in a real watch)

def rot(pts, deg):
    a = math.radians(deg); c, s = math.cos(a), math.sin(a)
    return [(x * c - y * s, x * s + y * c) for x, y in pts]

def tooth_poly(wheel_deg, k):
    return rot([(R + dx, dy) for dx, dy in TOOTH], k * PITCH + wheel_deg)

def stone_poly(fork_deg, which):
    lx, ly = ENTRY if which == 'entry' else EXIT
    a = math.radians(fork_deg); c, s = math.cos(a), math.sin(a)
    px = PIVOT[0] + lx * c - ly * s
    py = PIVOT[1] + lx * s + ly * c
    long_dir = (-math.sin(a), math.cos(a)); wid_dir = (math.cos(a), math.sin(a))
    hw, hl = SW / 2, SL / 2
    corner = lambda su, sv: (px + su * hl * long_dir[0] + sv * hw * wid_dir[0],
                             py + su * hl * long_dir[1] + sv * hw * wid_dir[1])
    return [corner(1, 1), corner(1, -1), corner(-1, -1), corner(-1, 1)]

def sat_overlap(p1, p2):
    """separating-axis test, convex polygons only"""
    def axes(p): return [(p[(i + 1) % len(p)][1] - p[i][1], p[i][0] - p[(i + 1) % len(p)][0]) for i in range(len(p))]
    def proj(p, ax):
        vals = [x * ax[0] + y * ax[1] for x, y in p]; return min(vals), max(vals)
    for poly in (p1, p2):
        for ax in axes(poly):
            a1, a2 = proj(p1, ax); b1, b2 = proj(p2, ax)
            if a2 < b1 or b2 < a1: return False
    return True

def hits(wheel_deg, fork_deg):
    """the ONE physical question: does any tooth touch any stone?"""
    for k in range(N_TEETH):
        d = (k * PITCH + wheel_deg - 90) % 360
        if 40 < d < 320: continue          # only teeth near the fork zone
        tp = tooth_poly(wheel_deg, k)
        if sat_overlap(tp, stone_poly(fork_deg, 'entry')): return True
        if sat_overlap(tp, stone_poly(fork_deg, 'exit')):  return True
    return False

# ---------------- acceptance stats ----------------
def free_run(hits_fn, f, wmax=30.0, step=0.2):
    run = best = 0
    for i in range(int(wmax / step) + 1):
        if not hits_fn(i * step, f): run += 1; best = max(best, run)
        else: run = 0
    return best * step

def blocked_frac(hits_fn, f, wmax=24.0, step=0.2):
    ws = [i * step for i in range(int(wmax / step) + 1)]
    return sum(hits_fn(w, f) for w in ws) / len(ws)

def dead_zone_frac(hits_fn, fmax=12.0, step_f=1.0, wmax=24.0, step_w=0.25):
    fs = [i * step_f for i in range(int(fmax / step_f) + 1)] + \
         [-i * step_f for i in range(1, int(fmax / step_f) + 1)]
    dead = total = 0
    for wi in range(int(wmax / step_w) + 1):
        w = wi * step_w
        if not any(not hits_fn(w, f) for f in fs): dead += 1
        total += 1
    return dead / total

def report():
    b0 = blocked_frac(hits, 0)
    fr_n, fr_p = free_run(hits, -10), free_run(hits, +10)
    dz = dead_zone_frac(hits)
    print(f"LOCK   blocked@fork0      : {b0:.2f}  (want >= 0.35)")
    print(f"RELEASE free run @ -10deg : {fr_n:.1f} deg (want ~= {0.45*PITCH:.1f})")
    print(f"RELEASE free run @ +10deg : {fr_p:.1f} deg (want ~= {0.45*PITCH:.1f})")
    print(f"DEAD ZONES                : {dz:.3f} (want 0)")
    ok = b0 >= 0.35 and fr_n >= 0.45 * PITCH and fr_p >= 0.45 * PITCH and dz <= 0.02
    print("ACCEPTANCE:", "PASS" if ok else "FAIL")

# ---------------- the search that produced the frozen numbers ----------------
def search():
    best = None
    random.seed(42)
    for trial in range(3000):
        pivot_y = random.uniform(11.0, 14.0)
        sl = random.uniform(3.0, 4.5); sw = random.uniform(0.9, 1.4)
        entry = (random.uniform(-4.0, -0.8), random.uniform(-2.8, 0.0))
        exit_ = (random.uniform(0.8, 4.0), random.uniform(-2.8, 0.0))

        global PIVOT, SL, SW, ENTRY, EXIT
        saved = (PIVOT, SL, SW, ENTRY, EXIT)
        PIVOT, SL, SW, ENTRY, EXIT = (0.0, pivot_y), sl, sw, entry, exit_
        try:
            b0 = blocked_frac(hits, 0)
            if b0 < 0.35: continue
            HALF = 0.45 * PITCH
            fr_n, fr_p = free_run(hits, -10), free_run(hits, +10)
            if not (HALF <= fr_n < PITCH and HALF <= fr_p < PITCH): continue
            dz = dead_zone_frac(hits)
            if dz > 0.02: continue
            score = b0 + min(fr_n, fr_p) / 60 - dz * 5
            if best is None or score > best[0]:
                best = (score, (pivot_y, sl, sw, entry, exit_))
                print(f"trial {trial}: score {score:.2f} blocked@0={b0:.2f} "
                      f"free(-10)={fr_n:.1f} free(+10)={fr_p:.1f} dz={dz:.3f}")
        finally:
            PIVOT, SL, SW, ENTRY, EXIT = saved
    if best: print("BEST:", best[1])

if __name__ == '__main__':
    if '--search' in sys.argv: search()
    else: report()
