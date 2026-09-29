---
feature: pdf-scan-image-extract
status: delivered
updated: 2026-09-29
branch: master
commits: c4d9c96..HEAD
---

# 扫描 PDF 页图提取修复（空白页 / OCR 无字）

## Report

**What was built** — 扫描 PDF 页图提取全链路：Filter 支持 Name/Array/**间接引用**；`DCTDecode` 仍出 JPEG；`Flate/LZW/ASCII*` 经 lopdf；**`CCITTFaxDecode` G3/G4 经纯 Rust `fax` crate** 解码 → 1bpp → 灰度 PNG。提取失败返回「本页无法解码（滤镜 X）」，禁止空字节入缓存；UI failed 占位显示该文案；OCR 仅对 JPEG/PNG 魔数有效图运行。

**Verification** —
- `cargo test -p book_parser --lib`：148 passed（含 CCITT 闭环 4 项、`is_valid_image_bytes`、JPX 错误文案）
- `pdf_probe` 对《神迹六辩》：p0–p2 JPEG 正常；p10/p11/p20/p100 经 CCITT G4 解出 1570×2480 中文扫描页（约 9% 黑像素、~116KB PNG）
- `.\build_apk.ps1 -Abis arm64-v8a`：`app-arm64-v8a-release.apk`（64.4MB，libbridge.so ×1）成功

**Journey log** —
1. lopdf 0.45 `decode_filters` 不含 CCITT/JPX/DCT，报 `Unimplemented("decompression algorithms")`——扫描书空白根因。
2. 手写 G4 解码器 `a0 as u32` 在 a0=-1 时溢出导致整页空行；且 PDF G4 常字节对齐行。最终改用 pdf-rs `fax` crate。
3. PDF `BlackIs1=false` 时 PNG 极性曾取反（87% 黑）；T.4 游程输出视觉恒为 1=黑，直接映射即可。
4. 真书 G4 流以 `ff ff…` 开头（V0 白边+填充），不可当垃圾跳过。
5. 失败页必须出**可读文案**而非纯白/灰块——BookImageStore 存 error + TextPainter 画「本页无法解码…」。

## [S1] Problem

《神迹六辩》等扫描 PDF：
- **原图模式**大量页空白
- **OCR** 识别无内容
- 用户怀疑预处理放大导致空白

**实测定位（cargo run --example pdf_probe）**：

| 页 | 提取结果 |
|----|----------|
| p0–p2 | 合法 JPEG（`ff d8` JFIF，20万+ 字节）→ 可显示 |
| p10 / p11 / p20 | **失败**：`lopdf: missing feature ... decompression algorithms` |

**结论**：
1. 空白 ≠ 预处理放大；是 **`extract_page_image` 解压失败后仍出页/出空图**。
2. 本书混合编码：前几页 `DCTDecode`（JPEG，正常），后文多为 **`CCITTFaxDecode`（K=-1 G4）**。
3. OCR 拿不到像素 → 识别空；原图也空。

## [S2] Design

### 目标
任意扫描 PDF 页能取出可显示位图；失败页明确占位，不再静默空白。

### 方案

**A. 图像滤镜全链路（主）**
1. **识别滤镜**：`Filter` 可能是 Name / Array / **间接引用**，统一解析。
2. **按滤镜解码**：
   - `DCTDecode` → JPEG 原样
   - `FlateDecode`/`LZWDecode`/`ASCIIHex` 等 → lopdf → 原始采样 → PNG
   - **`CCITTFaxDecode`**：`fax` crate G3/G4 → 1bpp（1=黑）→ 灰度 PNG
   - `JPXDecode`：明确报「本页为 JPEG2000」
3. **失败不装空**：提取失败 → 页面显示「本页无法解码（滤镜 X）」，不写空图缓存。

**B. 显示侧**
- `BookImageStore` 存失败文案；failed 占位画 × + 文案。

**C. OCR**
- 仅对 JPEG/PNG 魔数有效图做预处理+识别；失败/空图跳过并记日志。

### 测试
- 本书 p0（JPEG）与 p10（CCITT G4）对照
- CCITT 闭环（fax 编→解）
- 失败页错误文案非纯白

## [S3] Out of Scope
- 为 JPX 绑定完整 openjpeg（体积大，可二期）
- OCR 精度再调

## Tasks
- [x] T1: Filter 间接引用解析 + 解码分发（JPEG/Flate/LZW）— acceptance: p0 仍 JPEG；Flate 页出 PNG (covers: S2)
- [x] T2: CCITTFax 1bpc 解码 → PNG — acceptance: 扫描传真页有字图 (covers: S2; depends: T1)
- [x] T3: 提取失败占位与日志；禁止空图入缓存 — acceptance: p10 显示错误文案 (covers: S2; depends: T1)
- [x] T4: OCR 仅对有效图；回归 probe — acceptance: 有图页 OCR 非空 (covers: S2; depends: T1, T3)
