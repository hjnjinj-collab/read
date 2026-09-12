//! 内置 JS 结构化提取规则集与执行器（路线2 规则层，D9：JS 主路径）
//!
//! 脚本契约：全局注入 `domJson`（dom_json.rs 产出的紧凑 JSON DOM），
//! 脚本递归遍历做语义分类/嵌套提取，返回
//! `{ body: {tag,classes,style}, blocks: ContentBlock IR 数组 }`。
//! 块携带 `anc` 祖先链中间字段（自身+祖先链），供 Rust css_lite
//! 物化 CSS 样式；物化完成后由 content_ir::strip_anc 剥离。
//! 行内 style 的 display:none 由脚本直接跳过子树。
//! 执行器持进程级持久 QuickJS Context（预算大于净化执行器：整章 DOM
//! 解析内存开销更高）；超时经 rquickjs 中断句柄实现真超时。
//! 失败/超时/无引擎时调用方回落纯文本提取。

use crate::clean_rules::AD_PATTERNS_JS_ARRAY;

/// 内置结构化提取规则（单一合并脚本）
///
/// 元素覆盖：p / h1-h6 / img·svg image / ul·ol·li（含嵌套列表）/ blockquote /
/// hr / table（caption·tr·th·td，thead/tbody/tfoot 透明；
/// colspan/rowspan v1 忽略、按文档序扁平化，单元格携带 td 链路与
/// 完整内容提取）；div 及未知块级标签为透明容器；行内标签文本并入
/// 所在段落，其中样式元素（span/em 等）额外产出 runs 字符区段。
pub const BUILTIN_EXTRACT_RULES_JS: &str = r#"
(function () {
    const MAX_DEPTH = 200;
    const INLINE = new Set([
        "span", "em", "strong", "b", "i", "u", "s", "a",
        "code", "small", "sub", "sup", "cite", "q", "mark",
    ]);

    function ws(s) {
        return s.replace(/[ \t\r\n\f\v\u00a0]+/g, " ").trim();
    }

    function classArrayOf(node) {
        const cls = (node.a && node.a.class) || "";
        return cls.match(/\S+/g) || [];
    }

    // 自身链路单元：[tag, class...]
    function selfEntry(node) {
        const entry = [node.t];
        const classes = classArrayOf(node);
        for (let i = 0; i < classes.length; i++) entry.push(classes[i]);
        return entry;
    }

    // 行内 style 的 display:none：整棵子树跳过（CSS 类隐藏由 Rust 层判定）
    function hiddenByStyle(node) {
        const st = (node.a && node.a.style) || "";
        return /display\s*:\s*none/i.test(st);
    }

    // 去广告：AD_PATTERNS 由执行器前置注入（与净化规则单一来源共享）
    function stripAds(t) {
        if (typeof AD_PATTERNS !== "undefined") {
            for (let i = 0; i < AD_PATTERNS.length; i++) t = t.replace(AD_PATTERNS[i], "");
        }
        return t;
    }

    // 行内语境文本累积（img 不并入文本，由调用方转为独立图块）
    function inlineText(node) {
        let out = "";
        const kids = node.c || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (typeof child === "string") { out += child; continue; }
            if (child.t === "br") { out += "\n"; continue; }
            if (child.t === "img" || child.t === "image") { continue; }
            out += inlineText(child);
        }
        return out;
    }

    function imgBlock(node, chain) {
        const a = node.a || {};
        return {
            type: "image",
            // HTML img 用 src；SVG image 用 xlink:href（SVG1.1）或 href（SVG2）
            resource_href: a.src || a["xlink:href"] || a.href || "",
            alt: a.alt || null,
            anc: chain.concat([selfEntry(node)]),
        };
    }

    // 行内富文本的边界哨兵：PUA 区两个码位。正文若天然含这两个字符
    // （个别字体用 PUA 放私有字形），在 push/markInline 入口剥除，
    // 保证偏移计算不受源文本干扰
    const MARK_OPEN = "\uE000";
    const MARK_SEP = "\uE001";

    // 回收哨兵对 → 字符区间（在全部规范化/去广告完成后的最终文本上扫描）
    function decodeMarks(t) {
        let out = "";
        const openStack = [];
        const marks = [];
        let i = 0;
        while (i < t.length) {
            if (t[i] === MARK_OPEN) {
                const close = t.indexOf(MARK_SEP, i);
                if (close < 0) { out += t[i]; i += 1; continue; }
                const tag = t.slice(i + 1, close);
                i = close + 1;
                if (tag.charAt(0) === "/") {
                    for (let s = openStack.length - 1; s >= 0; s--) {
                        if (openStack[s].id === tag.slice(1)) {
                            const m = openStack.splice(s, 1)[0];
                            marks.push({ id: m.id, start: m.start, end: out.length });
                            break;
                        }
                    }
                } else {
                    openStack.push({ id: tag, start: out.length });
                }
                continue;
            }
            out += t[i];
            i += 1;
        }
        return { text: out, marks: marks };
    }

    // 段落累积器：缓冲原始文本块，flush 时统一做空白规范与去广告，
    // 再按哨兵对回收行内样式区段。runs 的 anc 为行内元素自身+祖先链
    function newFlush(out, chain) {
        let buf = "";
        const styleChains = [];

        function sanitize(s) {
            return s.split(MARK_OPEN).join("").split(MARK_SEP).join("");
        }

        return {
            push(chunk) { buf += sanitize(chunk); },
            // 行内元素文本：哨兵包裹（嵌套行内元素被 inlineText 展平，
            // 天然「最外层胜出」）
            markInline(text, ancChain, footnoteRef) {
                text = sanitize(text);
                if (!text.length) return;
                const id = (styleChains.length).toString(36);
                styleChains.push({ anc: ancChain, ref: footnoteRef || null });
                buf += MARK_OPEN + id + MARK_SEP + text + MARK_OPEN + "/" + id + MARK_SEP;
            },
            flush() {
                // 按行规范空白：保留 <br> 产生的软换行，行内空白折叠为单空格
                let t = buf
                    .split("\n")
                    .map(ws)
                    .filter(function (s) { return s.length > 0; })
                    .join("\n")
                    .trim();
                buf = "";
                t = stripAds(t)
                    .split("\n")
                    .map(ws)
                    .filter(function (s) { return s.length > 0; })
                    .join("\n")
                    .trim();
                if (!t.length) return;
                const decoded = decodeMarks(t);
                const para = { type: "paragraph", text: decoded.text, anc: chain };
                // A34：p.note/note1 直接标本章说（瓦尔登湖章末注）
                var noteCls = false;
                for (var ci = 0; ci < chain.length; ci++) {
                    var path = chain[ci] || [];
                    for (var cj = 1; cj < path.length; cj++) {
                        var cn = String(path[cj]).toLowerCase();
                        if (cn === "note" || cn === "note1" || /footnote|endnote/.test(cn)) {
                            noteCls = true;
                            break;
                        }
                    }
                    if (noteCls) break;
                }
                if (noteCls) para.is_comment = true;
                const runs = decoded.marks
                    .filter(function (m) { return m.end > m.start; })
                    .map(function (m) {
                        const sc = styleChains[parseInt(m.id, 36)] || null;
                        const r = {
                            start: m.start,
                            end: m.end,
                            anc: sc ? sc.anc : null,
                        };
                        if (sc && sc.ref) r.footnote_ref = sc.ref;
                        return r;
                    });
                if (runs.length) para.runs = runs;
                out.push(para);
            },
        };
    }

    // chain 含 p 自身；段内产出的段落均携带该链路
    function paraBlocks(node, depth, out, chain) {
        if (depth > MAX_DEPTH) return;
        const f = newFlush(out, chain);
        const kids = node.c || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (typeof child === "string") { f.push(child); continue; }
            if (hiddenByStyle(child)) { f.flush(); continue; }
            const tag = child.t;
            if (tag === "br") { f.push("\n"); continue; }
            if (tag === "img" || tag === "image") { f.flush(); out.push(imgBlock(child, chain)); continue; }
            if (tag === "rp") continue;
            if (tag === "rt") {
                f.markInline(inlineText(child), chain.concat([selfEntry(child)]), null);
                continue;
            }
            if (tag === "ruby") {
                rubyContent(child, depth + 1, chain.concat([selfEntry(child)]), f, out);
                continue;
            }
            // A34: footnote ref anchors (href hash mN)
            if (tag === "a") {
                const href = (child.a && child.a.href) || "";
                const fm = href.match(/#(m\d+)$/);
                f.markInline(inlineText(child), chain.concat([selfEntry(child)]),
                    fm ? fm[1] : null);
                continue;
            }
            if (INLINE.has(tag)) {
                f.markInline(inlineText(child), chain.concat([selfEntry(child)]), null);
                continue;
            }
            // 段内出现块级元素（脏 HTML 容错）：先封段，再按块处理
            f.flush();
            walkBlocks(child, depth + 1, out, chain.concat([selfEntry(child)]));
        }
        f.flush();
    }

    function liContent(node, depth, chain) {
        const out = [];
        const f = newFlush(out, chain);
        const kids = node.c || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (typeof child === "string") { f.push(child); continue; }
            if (hiddenByStyle(child)) { f.flush(); continue; }
            const tag = child.t;
            if (tag === "br") { f.push("\n"); continue; }
            if (tag === "ul" || tag === "ol") {
                f.flush();
                out.push(listBlocks(child, tag === "ol", depth + 1,
                    chain.concat([selfEntry(child)])));
                continue;
            }
            if (tag === "img" || tag === "image") { f.flush(); out.push(imgBlock(child, chain)); continue; }
            if (tag === "rp") continue;
            if (tag === "rt") {
                f.markInline(inlineText(child), chain.concat([selfEntry(child)]), null);
                continue;
            }
            if (tag === "ruby") {
                rubyContent(child, depth + 1, chain.concat([selfEntry(child)]), f, out);
                continue;
            }
            if (INLINE.has(tag)) {
                f.markInline(inlineText(child), chain.concat([selfEntry(child)]), null);
                continue;
            }
            if (tag === "p") {
                f.flush();
                paraBlocks(child, depth + 1, out, chain.concat([selfEntry(child)]));
                continue;
            }
            f.flush();
            walkBlocks(child, depth + 1, out, chain.concat([selfEntry(child)]));
        }
        f.flush();
        return out;
    }

    function listBlocks(node, ordered, depth, chain) {
        const items = [];
        const kids = node.c || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (typeof child === "string" || child.t !== "li") continue;
            if (hiddenByStyle(child)) continue;
            items.push({ blocks: liContent(child, depth + 1,
                chain.concat([selfEntry(child)])) });
        }
        return { type: "list", ordered: !!ordered, items: items };
    }

    // ruby 注音：以 ruby 为处理单元（否则整体命中未知块级容错分支，
    // 基字与注音被拆段）。基字留在当前段落缓冲；rt 独立成 run
    // （anc 末位 ["rt"]，Rust 物化为小字号）；rp 括号丢弃；
    // 其余子节点按段内规则容错处理
    function rubyContent(ruby, depth, chain, f, out) {
        if (depth > MAX_DEPTH) return;
        const kids = ruby.c || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (typeof child === "string") { f.push(child); continue; }
            if (hiddenByStyle(child)) continue;
            const tag = child.t;
            if (tag === "rp") continue;
            if (tag === "rt") {
                f.markInline(inlineText(child), chain.concat([selfEntry(child)]), null);
                continue;
            }
            if (tag === "br") { f.push("\n"); continue; }
            if (tag === "img" || tag === "image") { f.flush(); out.push(imgBlock(child, chain)); continue; }
            if (INLINE.has(tag)) {
                f.markInline(inlineText(child), chain.concat([selfEntry(child)]), null);
                continue;
            }
            f.flush();
            walkBlocks(child, depth + 1, out, chain.concat([selfEntry(child)]));
        }
    }

    function tableBlock(node, tableChain) {
        let caption = null;
        const rows = [];

        // 单元格内容提取：文本/br/行内/图片/嵌套块级，段落携带
        // 「…table→tr→td」完整链路（td 自身为末位），供 Rust 物化
        // td 级选择器（如 table.vol-title td.vol-title-name）
        function cellContent(td, cellChain, depth, out) {
            if (depth > MAX_DEPTH) return;
            const f = newFlush(out, cellChain);
            const kids = td.c || [];
            for (let i = 0; i < kids.length; i++) {
                const child = kids[i];
                if (typeof child === "string") { f.push(child); continue; }
                if (hiddenByStyle(child)) { f.flush(); continue; }
                const tag = child.t;
                if (tag === "br") { f.push("\n"); continue; }
                if (tag === "img" || tag === "image") { f.flush(); out.push(imgBlock(child, cellChain)); continue; }
                if (tag === "rp") continue;
                if (tag === "rt") {
                    f.markInline(inlineText(child), cellChain.concat([selfEntry(child)]), null);
                    continue;
                }
                if (tag === "ruby") {
                    rubyContent(child, depth + 1, cellChain.concat([selfEntry(child)]), f, out);
                    continue;
                }
                if (INLINE.has(tag)) {
                    f.markInline(inlineText(child), cellChain.concat([selfEntry(child)]), null);
                    continue;
                }
                if (tag === "p") {
                    f.flush();
                    paraBlocks(child, depth + 1, out, cellChain.concat([selfEntry(child)]));
                    continue;
                }
                // 其余块级（div 等）：透明容器下沉
                f.flush();
                walkBlocks(child, depth + 1, out, cellChain.concat([selfEntry(child)]));
            }
            f.flush();
        }

        function handleTr(tr, trChain) {
            const row = [];
            const kids = tr.c || [];
            for (let i = 0; i < kids.length; i++) {
                const c = kids[i];
                if (typeof c === "string") continue;
                if ((c.t === "th" || c.t === "td") && !hiddenByStyle(c)) {
                    const cellChain = trChain.concat([selfEntry(c)]);
                    const blocks = [];
                    cellContent(c, cellChain, 0, blocks);
                    row.push({
                        header: c.t === "th",
                        blocks: blocks,
                        anc: cellChain,
                    });
                }
            }
            if (row.length) rows.push(row);
        }
        function walk(n, chain) {
            const kids = n.c || [];
            for (let i = 0; i < kids.length; i++) {
                const c = kids[i];
                if (typeof c === "string") continue;
                if (c.t === "caption") {
                    caption = ws(inlineText(c)) || null;
                } else if (c.t === "tr") {
                    handleTr(c, chain.concat([selfEntry(c)]));
                } else if (c.t === "thead" || c.t === "tbody" || c.t === "tfoot") {
                    walk(c, chain);
                }
            }
        }
        walk(node, tableChain);
        return { type: "table", caption: caption, rows: rows, anc: tableChain };
    }

    // chain 含 node 自身；子元素链路 = chain + 子自身条目
    function walkBlocks(node, depth, out, chain) {
        if (depth > MAX_DEPTH) return;
        const kids = node.c || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (typeof child === "string") {
                const t = ws(child);
                if (t.length) out.push({ type: "paragraph", text: t, anc: chain });
                continue;
            }
            if (hiddenByStyle(child)) continue;
            const tag = child.t;
            const childChain = chain.concat([selfEntry(child)]);
            if (tag === "h1" || tag === "h2" || tag === "h3"
                || tag === "h4" || tag === "h5" || tag === "h6") {
                const t = ws(inlineText(child));
                if (t.length) {
                    out.push({
                        type: "heading",
                        level: parseInt(tag.charAt(1), 10),
                        text: t,
                        anc: childChain,
                    });
                }
            } else if (tag === "p") {
                paraBlocks(child, depth + 1, out, childChain);
            } else if (tag === "img" || tag === "image") {
                // HTML img 与 SVG image（svg 容器走下方透明分支递归到 image）
                out.push(imgBlock(child, chain));
            } else if (tag === "ul" || tag === "ol") {
                out.push(listBlocks(child, tag === "ol", depth + 1, childChain));
            } else if (tag === "blockquote") {
                const inner = [];
                walkBlocks(child, depth + 1, inner, childChain);
                if (inner.length) out.push({ type: "quote", blocks: inner });
            } else if (tag === "hr") {
                out.push({ type: "rule" });
            } else if (tag === "table") {
                out.push(tableBlock(child, childChain));
            } else {
                // div/section/article/body/figure 等：透明容器
                // 本章说：aside / footnote 语义 + class note/note1（瓦尔登湖式章末注）
                var cls = (child.a && child.a["class"]) || "";
                var isComment = (tag === "aside")
                    || (/footnote|endnote|sidenote|annotation|remark/.test(child.a && (child.a["epub:type"] || child.a.type || "")))
                    || (/footnote|endnote|sidenote/.test(cls))
                    || (/(^|\s)note1?(\s|$)/.test(cls));
                if (isComment) {
                    // 本章说段落：透明递归产出块后逐块标记 is_comment
                    var innerBlocks = [];
                    walkBlocks(child, depth + 1, innerBlocks, childChain);
                    for (var bi = 0; bi < innerBlocks.length; bi++) {
                        if (innerBlocks[bi].type === "paragraph") {
                            innerBlocks[bi].is_comment = true;
                        }
                        out.push(innerBlocks[bi]);
                    }
                } else {
                    walkBlocks(child, depth + 1, out, childChain);
                }
            }
        }
    }

    const root = JSON.parse(domJson);
    const blocks = [];
    const footnotes = {};
    // A34: harvest chapter-end notes (class note/note1 or footnote)
    function harvestNotes(node) {
        if (!node || typeof node === "string") return;
        if (node.t === "p" || node.t === "div" || node.t === "li") {
            const cls = (node.a && node.a.class) || "";
            if (/(^|\s)note1?(\s|$)/.test(cls) || /footnote|endnote/.test(cls)) {
                let id = null;
                const kids = node.c || [];
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i];
                    if (k && typeof k !== "string" && k.t === "a" && k.a && k.a.id && /^m\d+$/.test(k.a.id)) {
                        id = k.a.id;
                        break;
                    }
                }
                const raw = inlineText(node).replace(/^\s*\[\d+\]\s*/, "").trim();
                if (id && raw.length) footnotes[id] = raw;
            }
        }
        const kids = node.c || [];
        for (let i = 0; i < kids.length; i++) harvestNotes(kids[i]);
    }
    harvestNotes(root);
    walkBlocks(root, 0, blocks, [selfEntry(root)]);
    return {
        body_tag: root.t,
        body_classes: classArrayOf(root),
        body_style: (root.a && root.a.style) || "",
        blocks: blocks,
        footnotes: footnotes,
    };
})()
"#;

/// 去广告前置片段：以 var 注入全局 AD_PATTERNS（var 可重复 eval，
/// 与主脚本合并为一次 eval 执行）
fn ad_patterns_setup_js() -> String {
    format!("var AD_PATTERNS = [{}];", AD_PATTERNS_JS_ARRAY)
}

/// 单次执行超时（毫秒）：DOM 遍历比净化脚本重，5 秒为极端余量
const EXEC_TIMEOUT_MS: u64 = 5000;
/// 反序列化后块数上限（异常输出的最后防线）
const MAX_BLOCKS: usize = 20_000;

/// JS 提取结果（背景等页面级属性由调用方结合 CSS 计算）
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ExtractedContent {
    pub body_tag: String,
    pub body_classes: Vec<String>,
    pub body_style: String,
    pub blocks: Vec<crate::content_ir::ContentBlock>,
    /// A34：章末脚注表
    #[serde(default)]
    pub footnotes: std::collections::BTreeMap<String, String>,
}

#[cfg(feature = "js-engine")]
mod imp {
    use super::{ad_patterns_setup_js, BUILTIN_EXTRACT_RULES_JS, EXEC_TIMEOUT_MS};
    use crate::extract_rules::{ExtractedContent, MAX_BLOCKS};
    use anyhow::Context as _;
    use rquickjs::{Context, Runtime};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Mutex, OnceLock};
    use std::time::{Duration, Instant};

    /// 持久执行器（Mutex 保证串行；预算高于净化执行器——整章 DOM 更重）
    struct Executor {
        runtime: Runtime,
        context: Context,
    }

    static EXECUTOR: OnceLock<Mutex<Option<Executor>>> = OnceLock::new();
    static FAILURE_LOGGED: AtomicBool = AtomicBool::new(false);

    fn executor_slot() -> &'static Mutex<Option<Executor>> {
        EXECUTOR.get_or_init(|| Mutex::new(None))
    }

    pub fn run_extract(dom_json: &str) -> anyhow::Result<ExtractedContent> {
        let mut guard = executor_slot()
            .lock()
            .map_err(|_| anyhow::anyhow!("JS 提取执行器锁中毒"))?;

        if guard.is_none() {
            let runtime = Runtime::new().context("创建 JS Runtime 失败")?;
            runtime.set_memory_limit(128 * 1024 * 1024);
            runtime.set_max_stack_size(4 * 1024 * 1024);
            let context = Context::full(&runtime).context("创建 JS Context 失败")?;
            *guard = Some(Executor { runtime, context });
        }
        let exec = guard.as_ref().unwrap();

        // 中断句柄实现真超时；每次执行前重设截止时间
        let deadline = Instant::now() + Duration::from_millis(EXEC_TIMEOUT_MS);
        let handler: rquickjs::runtime::InterruptHandler =
            Box::new(move || Instant::now() >= deadline);
        exec.runtime.set_interrupt_handler(Some(handler));

        let json_str: String = exec.context.with(|ctx| -> anyhow::Result<String> {
            ctx.globals()
                .set("domJson", dom_json)
                .context("设置 domJson 变量失败")?;

            // 去广告正则前置注入 + 主提取脚本，一次 eval
            let script =
                format!("{}\n{}", ad_patterns_setup_js(), BUILTIN_EXTRACT_RULES_JS);
            let result: rquickjs::Value =
                ctx.eval(script).context("执行 JS 提取规则失败")?;

            let s: String = ctx
                .json_stringify(result)
                .context("序列化 IR 结果失败")?
                .ok_or_else(|| anyhow::anyhow!("JS 返回值为 undefined"))?
                .get()
                .context("读取 IR JSON 字符串失败")?;
            Ok(s)
        })?;

        let output: ExtractedContent =
            serde_json::from_str(&json_str).context("解析 IR JSON 失败")?;
        if output.blocks.len() > MAX_BLOCKS {
            anyhow::bail!(
                "IR 块数超过上限: {} > {}",
                output.blocks.len(),
                MAX_BLOCKS
            );
        }
        Ok(output)
    }

    /// 失败告警限频：仅首次记录
    pub fn warn_once(err: &anyhow::Error) {
        if !FAILURE_LOGGED.swap(true, Ordering::Relaxed) {
            log::warn!("JS 提取规则执行失败，后续回落纯文本兜底: {}", err);
        }
    }
}

/// 以 JS 主路径提取章节结构化内容。
///
/// 返回：
/// - `Some(Ok(content))`：提取成功（含 body 元数据与带 anc 链的块流）；
/// - `Some(Err(_))`：JS 执行失败（已限频告警），调用方须回落纯文本兜底；
/// - `None`：极简构建（js-engine 关闭），调用方直接走纯文本兜底。
pub fn extract_structured(
    dom_json: &str,
) -> Option<anyhow::Result<ExtractedContent>> {
    #[cfg(feature = "js-engine")]
    {
        match imp::run_extract(dom_json) {
            Ok(content) => Some(Ok(content)),
            Err(e) => {
                imp::warn_once(&e);
                Some(Err(e))
            }
        }
    }
    #[cfg(not(feature = "js-engine"))]
    {
        let _ = dom_json;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_ir::{Align, ContentBlock};
    use crate::dom_json::xhtml_to_dom_json;

    fn extract_html(html: &str) -> ExtractedContent {
        let dom = xhtml_to_dom_json(html, 8 * 1024 * 1024).expect("DOM 构建失败");
        extract_structured(&dom)
            .expect("默认特性下 JS 主路径必须可用")
            .expect("内置规则不应执行失败")
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn walden_style_endnotes() {
        // 瓦尔登湖式：正文 <a href="#m1"><sup>[1]</sup></a> + 章末 <p class="note">
        let html = r#"<html><body>
            <p>康科德<a id="w1"></a><a href="chapter001.html#m1"><sup>[1]</sup></a>的瓦尔登湖。</p>
            <p class="note"><a id="m1"></a><a href="chapter001.html#w1">[1]</a> 地名注释正文。</p>
        </body></html>"#;
        let content = extract_html(html);

        assert!(
            content.footnotes.contains_key("m1"),
            "应采集章末注 m1，实得 {:?}",
            content.footnotes.keys().collect::<Vec<_>>()
        );
        let body = content.footnotes.get("m1").unwrap();
        assert!(body.contains("地名注释正文"), "注释正文应去掉 [N] 前缀: {body}");
        assert!(!body.trim_start().starts_with("[1]"), "不应含 [1] 前缀: {body}");

        // note 段应标 is_comment
        let note_para = content.blocks.iter().find_map(|b| match b {
            ContentBlock::Paragraph { text, is_comment, .. } if text.contains("地名") => {
                Some(*is_comment)
            }
            _ => None,
        });
        assert_eq!(note_para, Some(true), "class=note 段应为本章说");

        // 正文引用 run 应带 footnote_ref=m1
        let has_ref = content.blocks.iter().any(|b| match b {
            ContentBlock::Paragraph { runs, .. } => runs
                .iter()
                .any(|r| r.footnote_ref.as_deref() == Some("m1")),
            _ => false,
        });
        assert!(has_ref, "正文 [1] 应产出 footnote_ref=m1 的 run");
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn heading_paragraph_rule_image() {
        let html = r#"<html><head><title></title></head><body>
            <h2 class="head">天行健</h2>
            <div class="logo"><img alt="logo" class="logo" src="../Images/logo.png"/></div>
            <hr/>
            <p>第一段</p>
            <script>ignore()</script>
        </body></html>"#;
        let content = extract_html(html);

        assert_eq!(content.body_tag, "body");
        assert_eq!(content.body_classes.len(), 0);

        assert_eq!(
            content.blocks[0],
            ContentBlock::Heading {
                level: 2,
                text: "天行健".to_string(),
                align: None,
                color: None,
                font_scale: None,
                anc: Some(vec![
                    vec!["body".to_string()],
                    vec!["h2".to_string(), "head".to_string()],
                ]),
            }
        );

        // 图片位于 div.logo 内：anc 应包含 body→div.logo→img.logo 全链
        assert_eq!(
            content.blocks[1],
            ContentBlock::Image {
                resource_href: "../Images/logo.png".to_string(),
                alt: Some("logo".to_string()),
                width_percent: None,
                align: None,
                intrinsic: None,
                bleed: false,
                hidden: false,
                anc: Some(vec![
                    vec!["body".to_string()],
                    vec!["div".to_string(), "logo".to_string()],
                    vec!["img".to_string(), "logo".to_string()],
                ]),
            }
        );

        assert_eq!(content.blocks[2], ContentBlock::Rule);
        let ContentBlock::Paragraph { text, align, .. } = &content.blocks[3] else {
            panic!("应为段落");
        };
        assert_eq!(text, "第一段");
        assert_eq!(*align, None);
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn svg_wrapped_cover_image() {
        // 《剑来》封面页形态：svg 包裹的 image（xlink:href）+ 隐藏标题
        let html = r#"<html><head><title>Cover</title></head><body>
            <h2 style="display:none">封面</h2>
            <div style="text-align: center;">
              <svg xmlns="http://www.w3.org/2000/svg" height="100%" width="100%" xmlns:xlink="http://www.w3.org/1999/xlink">
                <image width="1000" height="1333" xlink:href="../Images/cover.jpg"/>
              </svg>
            </div>
        </body></html>"#;
        let content = extract_html(html);

        // 隐藏 h2 不产出块；svg 容器透明下沉，image 产出图块
        assert_eq!(content.blocks.len(), 1, "应恰好产出封面图一个块");
        assert_eq!(
            content.blocks[0],
            ContentBlock::Image {
                resource_href: "../Images/cover.jpg".to_string(),
                alt: None,
                width_percent: None,
                align: None,
                intrinsic: None,
                bleed: false,
                hidden: false,
                anc: Some(vec![
                    vec!["body".to_string()],
                    vec!["div".to_string()],
                    vec!["svg".to_string()],
                    vec!["image".to_string()],
                ]),
            }
        );
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn br_splits_and_inline_accumulates() {
        use crate::content_ir::StyledRun;
        let html = "<html><body><p>甲<b>加粗</b><br/>乙<span>尾</span></p></body></html>";
        let content = extract_html(html);
        assert_eq!(
            content.blocks[0],
            ContentBlock::Paragraph {
                text: "甲加粗\n乙尾".to_string(),
                align: None,
                color: None,
                font_scale: None,
                runs: vec![
                    StyledRun {
                        start: 1,
                        end: 3,
                        color: None,
                        font_scale: None,
                        bold: false,
                        italic: false,
                        underline: false,
                        anc: Some(vec![
                            vec!["body".to_string()],
                            vec!["p".to_string()],
                            vec!["b".to_string()],
                        ]),
                        footnote_ref: None,
                    },
                    StyledRun {
                        start: 5,
                        end: 6,
                        color: None,
                        font_scale: None,
                        bold: false,
                        italic: false,
                        underline: false,
                        anc: Some(vec![
                            vec!["body".to_string()],
                            vec!["p".to_string()],
                            vec!["span".to_string()],
                        ]),
                        footnote_ref: None,
                    },
                ],
                anc: Some(vec![
                    vec!["body".to_string()],
                    vec!["p".to_string()],
                ]),
                is_comment: false,
                indent_first_line_em: None,
                spacing_after_em: None,
                line_height: None,
            }
        );
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn nested_list_and_table() {
        let html = "<html><body>\
            <ol><li>外层<ul><li>内层</li></ul></li><li>第二项</li></ol>\
            <table><caption>表</caption><tr><th>H</th></tr><tr><td>D</td></tr></table>\
        </body></html>";
        let content = extract_html(html);
        assert!(matches!(content.blocks[0], ContentBlock::List { ordered: true, .. }));
        let ContentBlock::List { items, .. } = &content.blocks[0] else {
            panic!("应为列表");
        };
        assert_eq!(items.len(), 2);
        assert!(matches!(
            items[0].blocks[1],
            ContentBlock::List { ordered: false, .. }
        ));
        let ContentBlock::Paragraph { text, .. } = &items[1].blocks[0] else {
            panic!("应为段落");
        };
        assert_eq!(text, "第二项");
        assert!(matches!(content.blocks[1], ContentBlock::Table { .. }));
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn dirty_html_tolerated() {
        let html = "<html><body><div><p>甲<div>乙</div></p></div></body></html>";
        let content = extract_html(html);
        let texts: Vec<_> = content
            .blocks
            .iter()
            .filter_map(|b| match b {
                ContentBlock::Paragraph { text, .. } => Some(text.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(texts, vec!["甲".to_string(), "乙".to_string()]);
    }

    /// 行内 style="display:none" 的装饰标题必须整树跳过（《剑来》part 页形态）
    #[cfg(feature = "js-engine")]
    #[test]
    fn inline_display_none_skipped() {
        let html = r#"<html><body class="qmp2">
            <h2 style="display:none">陈平安</h2>
            <p>&#160;</p>
            <p style="display : none">隐藏段</p>
        </body></html>"#;
        let content = extract_html(html);
        assert_eq!(content.body_classes, vec!["qmp2".to_string()]);
        // &nbsp; 段落折叠后为空被过滤，隐藏标题不产出任何块
        assert!(content.blocks.is_empty());
    }

    /// 去广告与净化规则同源：整段广告被剔除、正常段落保留
    #[cfg(feature = "js-engine")]
    #[test]
    fn ad_patterns_filter_paragraphs() {
        let html = "<html><body>\
            <p>本书由笔趣阁首发，请继续阅读。</p>\
            <p>正文甲。</p>\
            <p>正文乙 www.example.com 尾部。</p>\
        </body></html>";
        let content = extract_html(html);
        let texts: Vec<_> = content
            .blocks
            .iter()
            .filter_map(|b| match b {
                ContentBlock::Paragraph { text, .. } => Some(text.clone()),
                _ => None,
            })
            .collect();
        // 整段广告剔除
        assert!(!texts.iter().any(|t| t.contains("首发")));
        assert!(texts.contains(&"正文甲。".to_string()));
        // 段内广告句替换后剩余文本保留
        assert!(texts.contains(&"正文乙 尾部。".to_string()));
    }

    /// body 元数据随提取输出（供 Rust css_lite 匹配背景）
    #[cfg(feature = "js-engine")]
    #[test]
    fn body_metadata_returned() {
        let html = r#"<html><body class="head vol-open"></body></html>"#;
        let content = extract_html(html);
        assert_eq!(content.body_tag, "body");
        assert_eq!(
            content.body_classes,
            vec!["head".to_string(), "vol-open".to_string()]
        );
        assert_eq!(content.body_style, "");
    }

    /// 对齐字段经 serde 默认值补齐后可读
    #[cfg(feature = "js-engine")]
    #[test]
    fn align_defaults_none() {
        let html = "<html><body><h1>标题</h1></body></html>";
        let content = extract_html(html);
        let ContentBlock::Heading { align, .. } = &content.blocks[0] else {
            panic!("应为标题");
        };
        assert_eq!(*align, None::<Align>);
    }

    /// 行内样式元素产出 runs 区段：边界正确、anc 以行内元素为末位
    #[cfg(feature = "js-engine")]
    #[test]
    fn inline_runs_carry_span_chain_and_boundaries() {
        use crate::content_ir::StyledRun;
        let html = "<html><body>\
            <p>前缀<span class=\"txtu\">红字</span>中<em>斜体</em>尾</p>\
        </body></html>";
        let content = extract_html(html);
        let ContentBlock::Paragraph { text, runs, .. } = &content.blocks[0] else {
            panic!("应为段落");
        };
        // 前缀(0..2) 红字(2..4) 中(4..5) 斜体(5..7) 尾(7)
        assert_eq!(text, "前缀红字中斜体尾");
        assert_eq!(
            runs,
            &vec![
                StyledRun {
                    start: 2,
                    end: 4,
                    color: None,
                    font_scale: None,
                    bold: false,
                    italic: false,
                    underline: false,
                    anc: Some(vec![
                        vec!["body".to_string()],
                        vec!["p".to_string()],
                        vec!["span".to_string(), "txtu".to_string()],
                    ]),
                    footnote_ref: None,
                },
                StyledRun {
                    start: 5,
                    end: 7,
                    color: None,
                    font_scale: None,
                    bold: false,
                    italic: false,
                    underline: false,
                    anc: Some(vec![
                        vec!["body".to_string()],
                        vec!["p".to_string()],
                        vec!["em".to_string()],
                    ]),
                    footnote_ref: None,
                },
            ]
        );
    }

    /// 软换行不打断样式区段；无行内样式的段落不产 runs
    #[cfg(feature = "js-engine")]
    #[test]
    fn run_spans_soft_break_and_plain_para_has_no_runs() {
        let html = "<html><body>\
            <p><span class=\"txtu\">红<br/>字</span></p>\
            <p>纯文本</p>\
        </body></html>";
        let content = extract_html(html);
        let ContentBlock::Paragraph { text, runs, .. } = &content.blocks[0] else {
            panic!("应为段落");
        };
        // 红(\n)字 → 红=0 \n=1 字=2，区段覆盖全段
        assert_eq!(text, "红\n字");
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].start, 0);
        assert_eq!(runs[0].end, 3);

        let ContentBlock::Paragraph { runs, .. } = &content.blocks[1] else {
            panic!("应为段落");
        };
        assert!(runs.is_empty(), "纯文本段落不应有 runs");
    }

    /// 表格单元格携带 td 完整链路（table→tr→td 为末位），单元格内
    /// 段落同链路；嵌套块级（div 包裹）也能下沉提取
    #[cfg(feature = "js-engine")]
    #[test]
    fn table_cells_carry_td_chain() {
        let html = "<html><body>\
            <table class=\"vol-title\"><tr>\
            <td class=\"vol-title-name\">卷</td>\
            <td class=\"vol-title-number\"><div>一</div></td>\
            </tr></table>\
        </body></html>";
        let content = extract_html(html);
        let ContentBlock::Table {
            rows, anc, ..
        } = &content.blocks[0]
        else {
            panic!("应为表格");
        };
        assert_eq!(
            anc.as_ref().unwrap(),
            &vec![
                vec!["body".to_string()],
                vec!["table".to_string(), "vol-title".to_string()],
            ]
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].len(), 2);
        assert_eq!(
            rows[0][0].anc.as_ref().unwrap().last().unwrap(),
            &vec!["td".to_string(), "vol-title-name".to_string()]
        );
        let ContentBlock::Paragraph { text, anc: panc, .. } = &rows[0][0].blocks[0] else {
            panic!("单元格应为段落");
        };
        assert_eq!(text, "卷");
        assert_eq!(
            panc.as_ref().unwrap().last().unwrap(),
            &vec!["td".to_string(), "vol-title-name".to_string()]
        );
        // div 透明下沉后内容不丢
        let ContentBlock::Paragraph { text, .. } = &rows[0][1].blocks[0] else {
            panic!("单元格应为段落");
        };
        assert_eq!(text, "一");
    }
}
