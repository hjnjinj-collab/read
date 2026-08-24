# EPUB 统一渲染规则（路线2：结构化 IR + CSS 物化 + 原生绘制）

> 更新: 2026-08-24（M5：粗斜体字形/列表符号/ruby 注音/表格线框/px·rgb）；2026-08-24（M4：阅读级简繁转换）；2026-08-23（M3：文字样式/行内富文本/表格排版）
> 地位: EPUB 富内容渲染管线的**权威规则描述**，以代码实际状态为准。
> 验收基准: 《剑来》（Duokan 制作，474 spine，416 章头出血图 + ~19 整页背景 + ~40 卷首页）
> 关联: ARCHITECTURE.md §A8 / css_lite.rs / content_ir.rs / extract_rules.rs / layout_engine::layout_items

---

## 0. 管线总览

```
spine XHTML（原始字节）
   │ ① 结构层：dom_json.rs — html5ever 容错解析
   ▼
JSON DOM {"t","a","c"}（根=body；script/style/template/noscript 跳过；
   │                      深度帽 512、序列化帽 8MB）
   │ ☆ 阅读级简繁转换（可选，M4）：convert_text_nodes 就地改写 c 数组
   │   字符串文本节点；标签名/属性天然不动（详见 §7）
   │ ② 规则层：extract_rules.rs ▓JS▓（D9：语义分类归 JS）
   ▼
{ body_tag, body_classes, body_style, blocks[+anc 祖先链] }
   │ ③ 标准化层：epub_parser + css_lite（CSS 级联属标准化，非提取规则，
   │    故在 Rust：JS 层拿不到 head/<link>，且匹配是确定性计算）
   ▼
StructuredContent v2 { version, background, body_classes, blocks }
   │                    （anc 已剥离；图片 href 已解析为 ZIP 全路径；
   │                     intrinsic 尺寸已探测；文字样式/runs/表格列宽已物化）
   │ ④ 布局层：layout_engine::layout_items（bridge 把块映射为 LayoutItem）
   ▼
Page[] = entries[(样式化 Text 行 | Image 矩形 | Rect 单元格线框)] + 字符锚点区间
   │    （表格在布局期折算为一组绝对定位文本行+线框矩形，绘制层无感知）
   │ ⑤ 绘制层：Flutter PagePainter（文本 TextPainter / 图片 paintImage /
   │    线框 drawRect stroke；粗斜体按用户开关绘制期合成）
   ▼
页面（背景图 → 图片 → 文本行，按坐标绝对定位）
```

兜底链（任一环节失败自动降级）：DOM 构建失败 / JS 失败超时 / 无引擎构建 /
块数 >2 万 ⇒ `html_to_text_structured` 纯文本逐行包 Paragraph
（背景信息丢失、图片变 `[图片: alt]` 占位）。

---

## 1. 元素支持矩阵

状态：✅ 完整支持　◐ 支持（有已知降级）　✗ 不支持（明确定论）

| XHTML 元素/特征 | 提取行为 | IR 块 | 渲染行为 | 状态 |
|---|---|---|---|---|
| `<p>` | 段落；行内子元素累积文本；`<br>`→软换行 `\n`；样式行内元素产出 runs | Paragraph{align,color,font_scale,runs} | 逐行断行绘制；颜色/字号缩放/对齐生效（见 §5） | ✅ |
| `<h1>`–`<h6>` | 标题，level=1..6；空标题丢弃 | Heading{align,color,font_scale} | CSS 颜色/字号倍率/对齐生效；**标题独立字号体系未做**（仅 CSS 倍率） | ◐ |
| `<img src alt>` | 独立图块；src 由 Rust 按内容目录解析为 ZIP 全路径 | Image | 见 §3 图片规则 | ✅ |
| `<svg><image xlink:href></svg>` | SVG 包裹图片（《剑来》封面页形态）：svg 容器透明下沉，image 同 img 提取（href 读 src→xlink:href→href）；配合 duokan-page-fullscreen 转整页背景（见 §3.1） | Image | 同 img 规则；全屏页转背景铺满裁切 | ✅ |
| `div.logo>img`（包裹容器） | anc 链携带祖先 class | Image | CSS 物化 width%/align/bleed 后绘制 | ✅ |
| `<ul>`/`<ol>`/`<li>` | 列表；li 内嵌套 ul/ol 递归；li 内 p/img 混排 | List{ordered,items} | 前序展平为段/图序列；**项目符号「• 」/编号「N. 」前缀渲染**（M5：bridge 层合成，见 §8；悬挂缩进不做、ol start 属性忽略恒从 1 起） | ✅ |
| `<blockquote>` | 引用块递归提取 | Quote | 展平为普通段落（**无缩进/竖线样式**） | ◐ |
| `<hr>` | 分隔线 | Rule | 渲染为「────────」文本行 | ◐ |
| `<table>` | caption/tr/th·td；thead/tbody/tfoot 透明；单元格完整内容提取并携带 td 链路 | Table{rows,margin_top_percent} | **原子双列/多列排版**：列宽提示+逐字竖排+单元格细灰线框（M5，见 §6） | ✅ |
| th/td colspan·rowspan | 忽略跨列跨行，按文档序对齐（允许参差行） | TableCell | 同上，跨列跨行错位 | ◐ |
| `<ruby>/<rt>/<rp>` | ruby 为处理单元：基字留段落缓冲、rt 独立成 run（anc 末位 ["rt"]）、rp 括号丢弃（M5） | Paragraph{runs} | rt 以 **0.5× 小字同基线跟随基字**（CSS font-size 可覆盖）；行高下限 1.0 不撑行；真上标形态不做（单基线模型） | ✅ |
| `<a href>` | 文本并入所在段落，产出 runs（anc 带 ["a"]） | Paragraph(内) | **下划线生效**（无开关恒应用）；颜色随段落/CSS；**无跳转** | ◐ |
| em/strong/b/i/u/s/span/code/small/sub/sup/cite/q/mark | 行内样式元素以 runs 区段携带 anc 链（嵌套时最外层胜出） | Paragraph.runs | CSS color/font-size 生效；**b/strong 粗、i/em/cite 斜（M5，标签 UA 默认语义 + CSS 声明覆盖，受用户开关控制，见 §8）**；u 下划线仍无 | ✅ |
| `<figure>/<figcaption>` | 透明容器：图块与题注段按文档序产出 | Image+Paragraph | 图与题注顺序正确，无绑定关系 | ◐ |
| `<svg>`（含 svg>image 封面） | 透明容器退化；封面经独立提取通道（OPF meta/properties），不走正文 | （封面=cover_data） | 封面进书架；正文内联 svg 不产块 | ◐ |
| `<div>/section/article/main…` | 透明容器递归 | —（穿透） | — | ✅ |
| `<script>/<style>/<template>/<noscript>` | 整树跳过 | — | — | ✅ |
| `style="display:none"` | JS 层直接跳过整棵子树（含隐藏 h2 标题页形态） | —（不产块） | — | ✅ |
| `<pre>` | 透明容器退化（等宽排版丢失） | Paragraph | 按正文样式 | ◐ |

## 2. CSS 物化规则（css_lite 子集）

### 2.1 选择器语法

| 形态 | 示例 | 支持 | 说明 |
|---|---|---|---|
| 标签 | `p` | ✅ | 大小写不敏感 |
| 类 | `.logo` | ✅ | 多类 `.a.b` 取交集 |
| 标签+类 | `img.logo` | ✅ | specificity (类数,标签数)=(1,1) |
| 后代组合器 | `table.vol-title td.name` | ✅ | 末段为主体，其余沿祖先链自近及远贪心回溯 |
| 逗号分组 | `h3, h4.head {}` | ✅ | 每选择器独立匹配 |
| 通配 | `*` | ✅ | 匹配任意元素 |
| 子代 `>` / 相邻 `+`/`~` / 属性 `[..]` / 伪类 `:x` | `ruby>rt` | ✗ | 解析期整条选择器静默放弃（损失仅装饰细节） |
| @media/@font-face/@keyframes | — | ✗ | 整块跳过 |
| @import/@charset | `@import url(fonts.css)` | ✗ | 忽略（字体还原不在范围） |

### 2.2 样式来源与级联

- 来源收集：章节 head 的 `<link rel=stylesheet>`（scraper 提取，href 按**章节内容目录**
  转 ZIP 路径）；CSS 内 `url(...)` 按 **CSS 文件自身目录** 二次解析。解析结果按书缓存。
- 级联优先级：内联 style（仅 display:none 由 JS 消费）> specificity `(类数,标签数)`
  字典序 > 文档序靠后者。多 `<link>` 依文档序合并后同一套规则生效。
- 未建模：id 选择器、`!important`（值解析时剥离）、继承属性通论——
  仅 text-align 显式实现继承。

### 2.3 属性白名单（其余解析但忽略）

| 属性 | 物化目标 | 单位处理 |
|---|---|---|
| width | Image.width_percent；**TableCell.width_em**（列宽提示） | 图片 %保留、px/em 忽略；td 仅 em |
| text-align | Paragraph/Heading/Image.align | center/right/left；justify≈left；**沿祖先链继承查找** |
| color | Paragraph/Heading/StyledRun.color | `#abc`/`#aabbcc` 规范化为小写 6 位；**rgb()/rgba()（alpha 忽略）/常用命名色 17 项解析（M5）**；**沿祖先链继承** |
| font-size | Paragraph/Heading/StyledRun.font_scale | em/% → 相对基准倍率；**px/pt → px(或 pt·4/3) ÷ 当前排版字号 换算倍率（M5）；rem 忽略**；**沿祖先链继承** |
| font-weight | StyledRun.bold | bold/bolder→粗、normal/lighter→常规（显式声明阻断继承）、数值 ≥550 粗其余常规（CSS 级联语义整体覆盖标签默认）（M5） |
| font-style | StyledRun.italic | italic/oblique→斜、normal 显式常规（M5） |
| display | Image.hidden（none 时过滤该块） | 仅关键字 none |
| duokan-bleed | Image.bleed | 关键字含 "left" 即出血（真实书唯一形态 lefttopright） |
| background(-image)/background | PageBackground.image_href | url() 提取；简写形态扫全文取 url(...) |
| background-size / background-position | PageBackground.size / .position | cover→Cover；contain→Contain；百分比/两值→Stretch；position 关键字原文透传 |
| margin | Table.margin_top_percent（仅 top 的 %）；盒模型简写展开为四长键 | `margin:20% 0 0 auto` → margin-top=20% 生效，其余方向忽略 |
| height / padding-* | （解析但未消费） | 预留 |

### 2.4 继承语义

- **可继承属性**（color/font-size/text-align）：自身声明优先，未命中时
  沿 anc 祖先链自近及远回溯取首个有效值（《剑来》`table.vol-title{color}`
  → td → 单元格段落 三级继承实测命中）。残缺声明（`margin-left:;` 解析为
  None）视同未声明，不阻断回溯。
- **不可继承属性**（width/display/margin-*/duokan-bleed 等）：仅匹配自身
  上下文；bleed 因声明在包裹容器上，单独实现显式沿链查找。

### 2.5 页面级背景（body class）

- 匹配上下文：body 元素自身（tag+classes）。逐样式表查询取**最后一次命中**。
- **绘制严格按 CSS 语义，不做桌面端替代策略**（用户验收定论：
  「样式表怎么写就怎么显示」）：
  - `Cover`（CSS cover，真实书默认）：等比缩放至铺满窗口，溢出部分按
    `background-position` 锚点裁切（qmp*/head 页均为 `bottom center`——底边对齐）
  - `Contain`：完整显示（BoxFit.contain，锚点同上）
  - `Stretch`（`100% 100%` 形态，如 body.bg）：拉伸铺满允许变形
  - position 关键字映射：left/right → 水平锚 −1/+1；top/bottom → 垂直锚
    −1/+1；缺省居中
- `background-attachment: fixed` 桌面端近似为每页重复铺放。

## 3. 图片专项

| 特性 | 规则 |
|---|---|
| 尺寸探测 | Rust 读条目前 64KB 手写 header 解析（PNG IHDR/JPEG SOFn/GIF LSD/WEBP VP8·VP8L·VP8X）；失败回退宽高比 0.75 |
| 默认宽度 | 内容区宽 × width_percent%（缺省 100%，即占满内容区） |
| 高度 | 宽 ÷ 探测宽高比（等比，绘制不变形） |
| 对齐 | align: left/center/right（缺省 left；章头图为 center） |
| 出血 bleed | 占满整窗宽 x=0、页首 y 贴顶、忽略 padding/width_percent/align；超高时改居中收窄保纵横比 |
| 超大图 | 高度上限=整页内容高（出血图=页高），超出等比收缩 |
| 原子性 | 图片是不可分割块：当前页放不下且页非空→整体推至次页；连续多图依次堆叠 |
| 锚点 | **图片不消耗字符锚点**；char_index 只随文本累加 |
| 资源通道 | FFI `get_book_resource(book_id, zip_path)`→Uint8List；Rust LRU(50) 字节缓存 |
| Flutter 缓存 | BookImageStore 键 `$bookId\|$href`，ui.Image 解码一次；未命中画灰底占位并异步解码重绘；换书 clear() |
| 兜底 | 纯文本兜底路径中 img 变 `[图片: alt]` 占位文本 |

### 3.1 全屏页（duokan-page-fullscreen → 整页背景）

- OPF spine itemref `properties` 含 `duokan-page-fullscreen` 的文档（Duokan
  全屏页语义，《剑来》封面页形态：SVG 100%×100% 包裹封面图）在解析期收集为
  全屏页集合
- 结构化提取后，若全屏页**恰好产出唯一 Image 块**（href 已解析为 ZIP 全路径），
  转为 `PageBackground{size: Cover}` + 清空 blocks——与 body class 装饰页
  （§2.5）走同一整页背景渲染通道，等比铺满、溢出裁切
- 防御约束：非单图全屏页不转换（防丢文本）；body CSS 背景与全屏图并存时
  全屏图胜出（它是页面的内容本体）

## 4. 分页与进度锚点

- 输入：LayoutItem[]（Text(TextItem{align,color,font_scale,runs}) |
  Image{href,aspect,width_percent,align,bleed} | Table(TableInput)）
- 文本分页镜像 layout_text 约定：段落完整性优先、MIN_LINES_PER_PAGE=3、
  段间距 paragraph_spacing；char_index 只随文本字符累加（每段末尾 +1 换行）。
  样式化路径的软换行 `\n` 不落入任何行区间，锚点按
  `行区间长度 + 行前换行数` 累计，与旧口径保持一致
- 表格为原子块（见 §6）：整表放不下当前页则推至次页；锚点消耗 =
  单元格全部字符 + 每个单元格段落 +1
- 纯背景装饰页：blocks 为空 + 有 background ⇒ 单张空页（page_count=1，
  start==end==0），由背景填充视觉
- 锚点恢复：`get_page_structured(anchor_char_offset)` 二分定位后**跳过与命中页
  同起点的纯图页**（装饰图页与后继文本页 start 相同）；超界锚点收敛到末页
- 列表前缀（M5）：「• 」/「N. 」为 bridge 层合成文本，前缀字符计入
  char_index 累计（runs 区间同步偏移，锚定自洽）——跨版本进度锚点微漂移
  与 hr→「────」同类，二分定位容错无损
- TXT 路径（layout_text）与本矩阵无关，其字符偏移语义被进度库精确依赖，
  两套分页核心有意分离、禁止合并重构

## 5. 文字样式与行内富文本专项

### 5.1 块级样式链路

```
CSS 声明 → css_lite 物化（自身+继承回溯）
  → Paragraph/Heading {color:#rrggbb, font_scale:f32, align}
  → LayoutItem::Text(TextItem) → TextLine{color, font_scale}（FFI 透传）
  → Dart PagePainter：TextStyle(color 解析, fontSize=基准×scale)
```

- 行高取**段落内最大字号倍率** × 基准行高（行内 run 可能大于块级），
  段内行高统一避免参差基线
- 对齐折算为行起点 x 平移（center/right），width 保持内容宽不变
- 默认样式（None 字段）不产生 FFI 载荷；Dart 回落主题默认色

### 5.2 行内富文本（runs）

- 提取层：paraBlocks/liContent 遇 INLINE 元素（span/em/…）时以 **PUA 私有区
  哨兵对**（\uE000 id \uE001 … \uE000/id \uE001）包裹其展平文本；flush 时在
  **全部空白规范与去广告完成后**的最终文本上回收边界——偏移天然免疫中间改写。
  源文本若含这两个哨兵码位，入口处剥除
- runs 携带行内元素 anc 链，Rust 物化解析 color/font_scale（继承语义覆盖外层
  段落）；嵌套行内元素被 inlineText 展平，**最外层样式胜出**
- 布局层按逐字符倍率测量换行；runs 与行的字符区间求交切分为 LineSeg
  （偏移转为行内坐标）；Dart 用 TextSpan children 分段绘制，间隙回填行级默认
- 边界防御：空区间/越界区间物化时过滤；Dart 侧 substring 前 clamp

### 5.3 已知取舍

- JS 字符串为 UTF-16 计数，Rust char 计数对 BMP 内中文字符等价；
  星表面文字/emoji 在样式区段内可能偏移 ±1（真实书未出现）
- **粗斜体为 Dart 绘制期合成**（M5）：Rust 测量保持单字体（字形缓存键
  不加 weight 维度），CJK 字 advance 基本不变；拉丁字符 w700 变宽约
  2-8%，行尾偶有轻微挤压或提前一字符换行——接受为已知限制
- Heading 块无 runs 字段：标题内的行内样式（含 b/i）不生效（JS 标题臂
  不走哨兵通道，四层缺口，真实书标题均纯文本，维持现状）

## 6. 表格排版专项（原子多列）

```
Table{rows, margin_top_percent} → LayoutItem::Table(TableInput)
  → layout_table：列宽分配 → 逐单元格按列宽换行 → 行高取最大者
  → 定位 TextLine 序列（x/y 为页面绝对坐标，绘制层无感知复用文本通道）
```

- **margin-top %**：表格前垂直留白 = 百分比 × 内容高（卷首页下移 20% 形态）
- **列宽分配**：同列 td width_em 最大值 × 基准字号；提示总量超内容宽等比收缩；
  无提示列均分剩余空间；全无提示等分
- **竖排还原**：《剑来》卷首标题 td 宽 1.2em ≈19px < 全角字宽 ⇒ 逐字换行，
  天然还原原书纵向标题形态；单元格内 text-align center 居中于列宽
- **原子性**：整表高度一次性计算，当前页放不下且页非空→整表翻次页；
  超整页高的表格允许溢出底部（真实书未出现，文档定论不做行列拆分续排）
- **垂直对齐**：一律 top（真实书两 td 均 vertical-align:top）
- **单元格线框（M5）**：layout_table 逐行攒每格 `(x=base_x+列前缀和,
  y=行顶, w=列宽, h=行高)`，经 PageEntry::Rect（引擎内部变体）→ FFI
  扁平 `is_table_frame: bool` 标志透传；Dart 端 stroke 描边 1px 细灰
  （0xFF999999）不填充；空表无矩形；margin-left:auto 右置随 base_x 自然跟随
- 锚点：单元格字符累计 + 每段落 +1；is_chapter_start 首行标记照常生效

## 7. 阅读级简繁转换（M4）

EPUB 结构化路径此前完全跳过阅读级预处理。M4 起支持**仅简繁转换**
（替换规则明确不进 EPUB），实现为 **DOM 文本节点预转换**：

| 项 | 规则 |
|---|---|
| 变换位置 | DOM 构建之后、JS 规则提取之前——`dom_json::convert_text_nodes` 就地只递归改写 `c` 数组中的字符串元素；标签名与属性值天然不动，class/style 选择器匹配不受影响 |
| D10 契约 | 变换先于 IR 构建 ⇒ PUA 哨兵回收与 StyledRun 区间全部在**转换后文本**上计算，行内样式区间天然对齐；布局/绘制层零感知 |
| 实现口径 | 唯一权威 `book_parser::chinese_convert`（zhconv 词组级，ARCHITECTURE D6）；编码 u8 与 TXT 同款：0=无 1=简→繁 2=繁→简 |
| 参数通道 | FFI 逐调用传参（`get_page_structured`/`get_page_count_structured` 同携带 chineseConvert，两函数必须同参否则页数/内容错位），非全局状态 |
| 缓存 | StructuredPageKey 携带 convert_mode，换模式即换缓存键，LRU 自然淘汰；锚点在转换后文本上二分定位，进度恢复不受影响 |
| 兜底路径 | structured_fallback 纯文本输出的 Paragraph 同样应用转换 |
| 词组级特性 | zhconv 按词组映射：字面无歧义词不变化属正常（如「皇后」繁体本就写作「皇后」），验证须用无歧义词组 |

**EPUB 有意不做**（定论勿误判为缺失）：替换净化规则（EPUB 无行级净化
需求；未来若引入必须同样前置到 DOM 文本层）、去重标题/重分段
（EPUB 段落为语义 `<p>`，无 TXT 行重组问题）、导入级 EpubCleanedBook
半退役缓存维持现状（结构化路径不依赖它）。

## 8. M5 渲染能力与用户开关

### 8.1 字形样式开关（粗体/斜体独立）

- **链路**：设置对话框「字形样式」两个 SwitchListTile → reader_provider
  `_boldEnabled/_italicEnabled`（默认双开，纯内存不持久化）→
  applyContentProcessingSettings 批量提交 → reader_page 组合参数传入
  PagePainter；**斜体仅 EPUB 生效**（TXT 无行内标记语义）
- **纯绘制期过滤原则**：两开关不进任何缓存键（StructuredPageKey 与 TXT
  options_hash 均不含），切换必缓存命中秒回、零缓存失效；Rust 测量与
  分页对开关无感知
- **TXT 章节标题加粗对齐**：`isChapterStart && boldOn && !renderAsEpub`
  时该行 baseStyle 加 w700——EPUB 结构化路径同样置位 is_chapter_start，
  必须格式门控防 EPUB 章首行误加粗；TextSpan 子段继承父级字重，
  segments 分支无需重复判断
- 物化双源：标签 UA 默认语义（b/strong→粗、i/em/cite→斜）+ CSS
  font-weight/font-style 声明覆盖（CSS 命中胜出，显式 normal 阻断继承）

### 8.2 其余 M5 能力速查

| 能力 | 规则所在 |
|---|---|
| ruby 小字跟随 | §1 ruby 行 / resolve_runs RUBY_SCALE=0.5 |
| 列表符号编号 | §1 ul/ol 行 / §4 锚点口径（bridge 层合成+runs 同步偏移） |
| 表格线框 | §6（Rect 条目 + is_table_frame 标志 + stroke 1px 细灰） |
| px/pt 字号换算 | §2.3 font-size 行（÷当前排版字号，DEFAULT_BASE_FONT_PX=18 为探针/诊断缺省） |
| rgb()/命名色 | §2.3 color 行 |

## 9. 明确不支持清单（定论，勿再误判为 bug）

1. 内嵌自定义字体还原（DK-*、zdy* 等）——系统字体渲染
2. id 选择器 / !important / @media 响应式
3. ruby 真·上标形态（单基线模型，现 0.5× 小字同基线跟随）；a 链接跳转
4. colspan·rowspan 跨列跨行（按文档序对齐、参差行错位）
5. u/s/sub/sup 的下划线/删除线/上下标字形；标题（Heading）内的行内样式；
   行内嵌套样式的最外层胜出语义
6. 正文内联 svg 矢量图形（仅支持 `svg>image` 纯图片包裹形态，见 §1/§3.1）；
   列表悬挂缩进与 ol start 起始编号
7. px/em/pt 绝对尺寸的图片宽度；rem 字号；合成粗体不参与 Rust 断行测量
   （拉丁字符行尾可能轻微挤压，见 §5.3）
8. 脚注（ol.duokan-footnote）交互
9. 表格 margin 的非 top 方向（右对齐 auto 忽略，表格整体左置）

## 10. 新元素接入涉及文件速查

| 层 | 文件 | 改什么 |
|---|---|---|
| 结构 | dom_json.rs | SKIP_TAGS 白名单（一般无需动） |
| 规则 | extract_rules.rs（JS 常量） | walkBlocks/paraBlocks 增加分支与输出形状 |
| IR | content_ir.rs | ContentBlock 变体或字段（serde default 保持向后兼容） |
| 物化 | epub_parser.rs apply_css_to_block + css_lite.rs 白名单 | 新属性→IR 字段 |
| 布局 | layout_engine lib.rs LayoutItem/layout_items | IR→布局项映射与测量 |
| FFI | bridge lib.rs/api.rs | PageInfo/PageEntryInfo 透传 + codegen |
| 绘制 | reader_page_widget.dart PagePainter | entries 分派绘制 |

> D9 提醒：语义分类的新增一律先考虑 JS 规则层实现；
> css_lite 只承接「class 组合 → 渲染语义」的确定性物化。
