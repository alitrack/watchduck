# watchduck

**在浏览器里用 DuckDB-WASM 跑的机械表擒纵机构。没有服务器、没有物理引擎——每一拍都是一条 SQL 查询。**

[English README](README.md)

灵感来自[《The Watchmaker: 用数据库造一块机械表》](https://sqlartist.github.io/posts/the-watchmaker-building-a-mechanical-watch-in-a-database/)（原作者先用 SQL Server Spatial，后迁 PostGIS）以及 Bartosz Ciechanowski 的 [Mechanical Watch](https://ciechanow.ski/mechanical-watch/)。

## 在线体验

[**在线演示 → alitrack.github.io/watchduck**](https://alitrack.github.io/watchduck/)（导航首页，三选一）：

- **[index34.html — Ep5 全机芯（34 零件 / 107 件）](https://alitrack.github.io/watchduck/index34.html)**——完整机芯 3D，拆卸循环 `m_blocked()` 直接在浏览器 DuckDB-WASM 里逐轮跑 SQL，8 轮黄金表浏览器内复现。几何是 868KB 预求解快照（wasm 单线程线性内存 ~256MB 装不下 107 件现场宏生成，OOM 实测），相位烘焙在几何里，但每条拆卸判决仍是浏览器里的一条 SQL。
- **[escapement3d.html — 3 零件擒纵组 · 3D](https://alitrack.github.io/watchduck/escapement3d.html)**——立体金属擒纵轮 + 红宝石叉石 + 摆轮游丝，实时走针，可拖拽旋转；~7.9 万次 `ST_Intersects` 现场建碰撞表，递归 SQL 逐 tick 求解。
- **[index2d.html — 2D 工程视图](https://alitrack.github.io/watchduck/index2d.html)**——同一引擎，正交轮廓，碰撞态在图上标红。

每个页面都是自包含静态 HTML（无构建、无后端），首次加载下载约 40 MB 的 DuckDB-WASM + spatial 扩展，之后离线可用。


## 你会看到什么

一个 15 齿的擒纵轮、带两颗宝石的擒纵叉、一个摆轮。擒纵叉以 5 拍/秒（18000 bph，经典机芯频率）摆动 ±10°。擒纵轮每拍前进半个齿距——**约 12°/拍，而代码里从没写过 12 这个数字**。它和真表一样，是从形状里「涌现」出来的。

## 原理——建模金属，不建数学

每个零件都是多边形。数据库只被问一个物理问题，反复问：

```sql
SELECT ST_Intersects(
  ST_Rotate(tooth, wheel_angle),
  ST_Rotate(stone, fork_angle)
);
```

1. **建碰撞图（一次性，SQL 完成）。** DuckDB-WASM 加载 `spatial` 扩展后，把「轮角 × 叉角」网格 cross join——约 9,500 个状态、约 79,000 次 `ST_Intersects`——写入 `collision_map` 表。这就是这块表的全部物理，由数据库预计算。
2. **跑表（每帧一条 SQL）。** 每个动画帧用三角波定位叉（像真摆轮在转折点有驻留），向数据库发一条 prepared query：*这个状态被卡住吗？* 空闲则轮前进，卡住则金属挡停。锁 → 放 → 锁 → 放：滴答。
3. **画（canvas）。** 浏览器只画 DuckDB 决定好的结果，自己从不做决定。

点 **“Show collision map”** 能看到真实的表：红 = 金属碰金属，绿 = 轮可通行。那条随叉角平移的水平自由走廊，**就是**擒纵机构。

## 仓库结构

```
index.html            导航首页（三张卡片，无引擎，秒开）
escapement3d.html     3 零件擒纵组 3D 视图（纯静态，无构建步骤）
index2d.html          3 零件擒纵组 2D 工程视图
index34.html          Ep5 34 零件全机芯 + 浏览器内 wasm 实时拆卸
movement_snapshot.json  Ep5 装配态快照（每件 world WKT，相位烘焙）
04_take_apart.sql     m_blocked 拆卸引擎（native + wasm 通用）
earcut.min.js         本地化的 earcut（index34 用它三角化 WKT 轮廓）
ep5_movement/         参考实现的 native DuckDB 移植（SQL + driver）
scripts/geometry.py   冻结的零件尺寸 + 找到这些尺寸的随机搜索
```

几何参数来自随机搜索，验收标准全是几何性的——中位摆角锁死、极端摆角放行约半齿距、零死区。`python3 scripts/geometry.py` 复验冻结几何仍达标，`--search` 重跑搜索。

## 为什么是 DuckDB

原作者被 SQL Server 逼去 PostGIS，因为 SQL Server 连 `ST_Rotate` 都没有——最快的旋转办法是改写 WKT 字符串。DuckDB 的 `spatial` 扩展原生带旋转/平移/相交，向量化执行，建图（约 7.9 万次相交判定）在 WASM 里几百毫秒完成。SQLite 用纯 SQL 手写 SAT 也能做（实测可行，慢约 300 倍）；文章后续的真 3D 部分仍是 PostGIS/SFCGAL 的主场——但 2D 擒纵机构，浏览器里的 DuckDB 就够了。

## 诚实的边界

- 摆轮只画了，没仿真惯性——叉按 5 Hz 三角波走（真实摆轮的相位由冲量涌现，属后续工作）。
- 释放期间轮是匀速，不是力矩驱动。
- 只有 2D（对应原文章 Part 1）。
- 齿形是凸四边形，不是摆线齿形。

## 许可

MIT — 见 [LICENSE](LICENSE)。
