# Showcase P0 — QA 记录（2026-11-13）

验收人：Hermes（协调者，机械验收 + 真实浏览器实测）。实现：pi@8017 Lane A（commits 571f86b…745fafe）。

## 机械验收（判据来自任务书，非工人自述）

| # | 判据 | 结果 |
|---|---|---|
| 1 | 分支 showcase-p0，≥5 commits，diff 范围限定 index/escapement3d/index2d/docs/assets | ✅ 5 commits + 1 协调者补充（d71ca14），范围合规 |
| 2 | baseline.md 含 ACCEPTANCE: PASS 与 geometry.py 四个真实数值 | ✅ LOCK 0.78 / 11.2 / 10.8 / dead zones 0 |
| 3 | Trace 侧栏 + 复制按钮 + 6 态加载状态机 + retry | ✅ grep 全命中（"Why did it tick" ×4；idle/downloading/instantiating/loading_spatial/building_map/ready/retry 全在） |
| 4 | diff 无伪造（写死 blocked / 假百分比 / 固定 12°） | ✅ 命中 3 行均为"不做假"的注释与占位说明 |
| 5 | geometry.py 在分支上仍 PASS | ✅ ACCEPTANCE: PASS |
| 6 | 禁区文件（geometry.py / 04_take_apart.sql / movement_snapshot.json）未触碰 | ✅ |

## 浏览器实测（Chromium，http://localhost:8000，2026-11-13 22:00–22:10）

**escapement3d.html**
- 冷启动状态机：downloading（带真实阶段耗时 0.5s）→ spatial loaded → collision map **4,753 states (1,438 blocked) / 95 ms** → ready。无百分比伪造。✅
- Start 后 12s：beats=11，deg/beat 涌现 252.16°/11 = 22.9°/beat 累计口径（面板显示 theory: half a tooth pitch）。✅
- P0-2 Trace 面板真实数据：statement `p_frame`（prepared）、绑定参数 `$1 wheel = 23° · $2 fork = -6°`、last verdict `○ FREE — blocked = 0`、SQL queries/frame 341 verdicts、Copy 按钮可用。✅ **数据来自真实查询路径，非合成**
- P0-4：demo path ①→⑤ 一行可见；▲/○ 图例文字+形状不只靠颜色；「What SQL computes vs what Three.js draws」分节说明在位；交叉链接 →2D / →34-part。✅

**index.html**
- Hero 标题 "A Mechanical Watch. Powered by SQL." ✅
- CTA：Run Live SQL Simulation → / View the SQL → 04_take_apart.sql / Break the Watch disabled（标注 opens in a later stage）✅
- 预览区诚实标注 "Recorded preview, not live SQL"；首屏不实例化 DuckDB-WASM（静态 HTML 验证）。✅
- poster 初始为占位图（工人按任务书标注），协调者已用实机运行截图替换（commit d71ca14）。✅

**index2d.html**：小改（图例/标注一致性），未重测全流程（无功能改动，低风险）。

**index34.html**：本轮未改。master 基线已验（GOLDEN MATCH ✓ / 8 rounds / 107 pieces）。

## 已知限制 / Not tested

- 手机 390×844 视口：Not tested（本环境无移动模拟器；P2-4 补）。
- Firefox / Safari：Not tested。
- 加载失败→Retry 路径：Not tested（需断网模拟；逻辑在位，grep 验证 retry 分支存在）。
- prefers-reduced-motion / 弱网：Not tested。
- 15 秒循环视频：未制作（本轮用真实静态截图作 poster，符合任务书 fallback：不允许伪造运转过程）。视频留 P2-3。

## 结论

P0-1/2/3/4 全部落地，机械验收 6/6，浏览器实测通过。可进入 sigil 复核 lane。
