---
feature: image-paper-tint
status: delivered
updated: 2026-09-29
branch: master
commits: 56222a6..3d274b7
---

# 图片纸色适配（漫画白边 / PDF 原图纸白）

## Report

**What was built** — 图片纸色适配分两套算法（shader `paper_tint.frag` 的 `uMode`）：**漫画**只把「图边近白」映射为纸色（四周约 14% 边缘带 + 高亮度低色度），图内白底/高光不动；**PDF** 对低色度像素做 `luma → (ink, paper)` 两端重映射并轻微抬对比，纸白吃背景、墨色吃正文色，暗色下字迹仍清晰。设置「图片纸色适配」可关；shader 失败回退 `paintImage`。

**Verification** —
- `dart analyze`（paper_tint / page widget / provider）：PASS（2 条既有 info）
- `flutter test test/paper_tint_test.dart --no-pub`：覆盖 边缘纯白映射 / 图内白不动 / 淡彩不动 / 线稿不动 / 边缘衰减 / PDF 低色度 / 彩色不映射 / 对比提升 / active 门控
- APK 见本轮交付（含新版 shader）

**Journey log** —
1. v1 全局近白映射会误伤**图内白底**；改为漫画只动 UV 边缘带。
2. PDF 暗色下「白→深纸 + 黑字仍黑」对比崩掉；改为墨色↔纸色两端重映射（正文色进 shader）。
3. 阈值收紧到 0.93 + 低色度门控，排除米白高光与淡彩。
4. `flutter pub get` 易挂起；验证用 `flutter test --no-pub` + `dart analyze`。

## [S1] Problem

1. **漫画**：部分图源自带上下大白边；高度又 ≥65% 走独页拉伸后，暗色模式下上下仍是刺眼纯白。
2. **PDF 原图**：扫描页以纸白为主，暗色主题下整页发白。
3. 用户对照 WPS「护眼」：即使 PDF 也会把纸面压成主题色；但明确要求**不要盖住画面**，只适配空白/纸白。

**v1 反馈（本修订）**：
- 全局近白映射会把**图内白色背景**也改掉（误伤）。
- PDF 原图模式**字迹发虚/不清晰**（反锯齿灰被混向纸色，或黑字未跟正文色）。

## [S2] Design

### 目标
只适配「纸/留白」，不毁画面；PDF 暗色下字迹对比与正文阅读一致。

### 合同

**A. 双模式 shader（`shaders/paper_tint.frag`）**

| 模式 | 规则 |
|------|------|
| `TintMode.comic` | `band = 1-smoothstep(0.55m, m, edgeDist)`，`m≈0.14`；`white = smoothstep(0.89,0.93,luma)*(1-smoothstep(0.05,0.12,chroma))`；`mix → paper` 仅当 `white*band` |
| `TintMode.pdf` | `doc = 1-smoothstep(0.10,0.22,chroma)`；`g=(luma-0.5)*1.08+0.5`；`mapped=mix(ink,paper,g)`；`mix(c,mapped,doc)` |

- **漫画**：边缘留白变纸色；图内白底、米白高光、淡彩不动。
- **PDF**：纸白→`paperColor`，墨黑→`textColor`，对比略抬；彩色插图/批注不映射。

**B. 适用范围**
- `format==comic` → comic 模式；`format==pdf` → pdf 模式；EPUB 不染。
- 设置 `imagePaperTint`（默认 true）关闭则 `paintImage`。

**C. 绘制**
- `PaperTint.paint(..., paper, ink, fallback)`；shader 失败回退。

### 测试
- 漫画：边缘纯白映射、图内白/淡彩/线稿不映射、边缘→中心衰减。
- PDF：低色度文档感、彩色不映射、luma 0/0.5/1 重映射与对比方向。
- 门控：enabled × imagesNeedTint。

## [S3] Out of Scope
- 整图 WPS 式绿膜
- 裁切白边改变布局
- OCR 预处理纸色

## Tasks
- [x] T1: paper_tint.frag + 绘制封装（阈值/强度/paper 色） — acceptance: 近白→纸色、暗色不变 (covers: S2)
- [x] T2: 漫画/PDF 默认启用 + 设置开关持久化 — acceptance: comic/pdf 生效，开关可关 (covers: S2)
- [x] T3: 回退与测试 — acceptance: shader 失败走 paintImage；阈值用例过 (covers: S2)
- [x] T4: 算法修订——漫画边缘带 + PDF 墨/纸重映射 — acceptance: 图内白不动、PDF 字迹清晰 (covers: S2)
