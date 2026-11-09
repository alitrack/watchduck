#!/bin/bash
set -e
cd /home/lhy/watchduck
python3 scripts/geometry.py | tail -1   # preflight: acceptance must PASS
python3 -c "import re;print('README zh chars:', len(re.findall(r'[\u4e00-\u9fff]',open('README.md').read())))"
git add README.md README_cn.md LICENSE index.html scripts/geometry.py .github/workflows/ci.yml
git commit -q -m "watchduck: Swiss lever escapement computed by DuckDB-WASM in the browser

- collision map built once in SQL (~9.5k states via ST_Intersects grid)
- every physics substep is one SQL query against esc_map (125 Hz virtual clock)
- emergent 12.00 deg/beat = half tooth pitch; nothing in code says 12
- geometry frozen by random search (scripts/geometry.py, CI-checked)"
git log --oneline -1
