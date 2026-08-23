//! 极简 CSS 子集解析器（EPUB 样式物化用）
//!
//! 只做一件事：把「选择器 + 声明」解析为可按元素上下文查询的样式表，
//! 供 epub_parser 将 class 组合规则物化为 IR 渲染语义
//! （图片宽度百分比/对齐、display:none、body 背景）。
//!
//! 语法覆盖真实书籍主流形态（以《剑来》main.css 校准）：
//! tag / `.class` / `tag.class` / 多类 `.a.b` / 后代组合器 / 逗号分组。
//! 子代 `>`、属性选择器、伪类、@media 等一律容错跳过——损失仅限
//! 装饰细节，不影响正文可读性。@import 忽略（字体还原不在范围内）。

use std::collections::HashMap;

/// 声明值（保留原始单位；换算基准由使用方决定）
#[derive(Debug, Clone, PartialEq)]
pub enum DeclValue {
    Px(f32),
    Em(f32),
    Pt(f32),
    Percent(f32),
    Keyword(String),
    Url(String),
    /// 声明存在但值为空（真实书里存在 `margin-left:;` 这类残缺声明）
    None,
}

impl DeclValue {
    /// 关键字小写比较
    pub fn is_keyword(&self, kw: &str) -> bool {
        matches!(self, DeclValue::Keyword(k) if k == kw)
    }
}

/// 复合选择器单元：`div.logo` → tag=Some("div"), classes=["logo"]
#[derive(Debug, Clone, PartialEq)]
struct CompoundSel {
    tag: Option<String>,
    classes: Vec<String>,
}

impl CompoundSel {
    /// (类数, 标签数)，用于简化版 specificity 比较
    fn specificity(&self) -> (usize, usize) {
        (
            self.classes.len(),
            usize::from(self.tag.is_some()),
        )
    }
}

/// 一条选择器：后代组合器拆分为复合单元序列（末位为匹配主体）
#[derive(Debug, Clone, PartialEq)]
struct CssSelector {
    compound: Vec<CompoundSel>,
}

impl CssSelector {
    /// 全链路 specificity 求和（与 CSS 规则同向：类权重 > 标签）
    fn specificity(&self) -> (usize, usize) {
        self.compound
            .iter()
            .fold((0, 0), |(c, t), s| (c + s.specificity().0, t + s.specificity().1))
    }
}

/// 规则：一组选择器 + 声明块
#[derive(Debug, Clone)]
struct CssRule {
    selectors: Vec<CssSelector>,
    decls: Vec<(String, DeclValue)>,
}

/// 已解析样式表：可按元素上下文查询生效声明
#[derive(Debug, Clone, Default)]
pub struct CssStylesheet {
    rules: Vec<CssRule>,
}

/// 元素匹配上下文（自身 + 祖先链；由 JS 层输出的 anc 链转换而来）
#[derive(Debug, Clone, Default)]
pub struct NodeCtx {
    pub tag: String,
    pub classes: Vec<String>,
    /// 祖先链（根 → 直接父节点），每项为 (tag, classes)
    pub ancestors: Vec<(String, Vec<String>)>,
}

impl CssStylesheet {
    /// 解析 CSS 文本；无效片段静默跳过，单条失败不影响其余规则
    pub fn parse(css_text: &str) -> Self {
        let text = strip_comments(css_text);
        let bytes = text.as_bytes();
        let mut rules = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            match bytes[i] {
                b' ' | b'\t' | b'\r' | b'\n' | b';' => i += 1,
                b'@' => {
                    // @import/@charset：语句到分号；@media/@font-face 等：整块跳过
                    let brace = text[i..].find('{').map(|p| i + p);
                    let semi = text[i..].find(';').map(|p| i + p);
                    match (brace, semi) {
                        (Some(b), _) if semi.map_or(true, |sc| b < sc) => i = skip_block(&text, b),
                        (_, Some(sc)) => i = sc + 1,
                        _ => break,
                    }
                }
                _ => {
                    let Some(open) = text[i..].find('{').map(|p| i + p) else {
                        break;
                    };
                    let end = skip_block(&text, open);
                    let prelude = text[i..open].trim();
                    let body = &text[open + 1..end.saturating_sub(1)];
                    let decls = parse_decls(body);
                    let selectors: Vec<CssSelector> =
                        prelude.split(',').filter_map(parse_selector).collect();
                    if !selectors.is_empty() && !decls.is_empty() {
                        rules.push(CssRule { selectors, decls });
                    }
                    i = end;
                }
            }
        }
        Self { rules }
    }

    /// 合并另一张样式表（后合并的优先级高，符合多 <link> 文档序语义）
    pub fn extend(&mut self, other: CssStylesheet) {
        self.rules.extend(other.rules);
    }

    /// 查询某元素上下文的全部生效声明（每属性取 specificity 最高者，
    /// 同级时文档序靠后者胜出）
    pub fn declarations(&self, ctx: &NodeCtx) -> HashMap<String, DeclValue> {
        // (specificity, DeclValue)；插入序天然承载「同级后者胜」
        let mut best: HashMap<String, ((usize, usize), DeclValue)> = HashMap::new();
        for rule in &self.rules {
            let mut hit: Option<(usize, usize)> = None;
            for sel in &rule.selectors {
                if selector_matches(sel, ctx) {
                    let spec = sel.specificity();
                    if hit.map_or(true, |cur| spec > cur) {
                        hit = Some(spec);
                    }
                }
            }
            let Some(spec) = hit else { continue };
            for (prop, val) in &rule.decls {
                match best.get_mut(prop) {
                    Some(entry) => {
                        if spec >= entry.0 {
                            *entry = (spec, val.clone());
                        }
                    }
                    None => {
                        best.insert(prop.clone(), (spec, val.clone()));
                    }
                }
            }
        }
        best.into_iter().map(|(k, (_, v))| (k, v)).collect()
    }
}

/// 移除 /* */ 注释（CSS 注释不嵌套）
fn strip_comments(text: &str) -> String {
    if !text.contains("/*") {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("/*") {
        out.push_str(&rest[..start]);
        match rest[start..].find("*/") {
            Some(end) => rest = &rest[start + end + 2..],
            None => return out,
        }
    }
    out.push_str(rest);
    out
}

/// 返回 open 处 `{` 对应 `}` 之后的位置（未闭合则到文末）
fn skip_block(text: &str, open: usize) -> usize {
    let bytes = text.as_bytes();
    let mut depth = 0usize;
    for (i, &b) in bytes.iter().enumerate().skip(open) {
        match b {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return i + 1;
                }
            }
            _ => {}
        }
    }
    bytes.len()
}

fn parse_selector(text: &str) -> Option<CssSelector> {
    let t = text.trim();
    // 不支持的语法：子代/属性/伪类/相邻兄弟——整条放弃
    if t.is_empty()
        || t.contains('>')
        || t.contains('[')
        || t.contains(':')
        || t.contains('+')
        || t.contains('~')
    {
        return None;
    }
    let compound: Vec<CompoundSel> = t.split_whitespace().filter_map(parse_compound).collect();
    if compound.is_empty() {
        None
    } else {
        Some(CssSelector { compound })
    }
}

fn parse_compound(part: &str) -> Option<CompoundSel> {
    let bytes = part.as_bytes();
    if bytes.is_empty() {
        return None;
    }
    if part == "*" {
        return Some(CompoundSel {
            tag: None,
            classes: Vec::new(),
        });
    }

    let mut tag = None;
    let mut idx = 0;
    if bytes[0] != b'.' {
        let end = part.find('.').unwrap_or(part.len());
        let t = &part[..end];
        if !t.is_empty() && t != "*" {
            if !t.chars().next().is_some_and(|c| c.is_alphabetic()) {
                return None;
            }
            tag = Some(t.to_ascii_lowercase());
        }
        idx = end;
    }

    let mut classes = Vec::new();
    while idx < part.len() {
        if bytes[idx] != b'.' {
            return None;
        }
        let start = idx + 1;
        let end = part[start..].find('.').map_or(part.len(), |p| start + p);
        let cls = &part[start..end];
        if cls.is_empty() {
            return None;
        }
        classes.push(cls.to_string());
        idx = end;
    }
    Some(CompoundSel { tag, classes })
}

fn parse_decls(body: &str) -> Vec<(String, DeclValue)> {
    let mut out: Vec<(String, DeclValue)> = Vec::new();
    for d in body.split(';') {
        let Some((prop, value)) = d.split_once(':') else {
            continue;
        };
        let prop = prop.trim().to_ascii_lowercase();
        if prop.is_empty() {
            continue;
        }
        let raw_value = value.trim().to_string();
        let value = parse_decl_value(&prop, value);
        out.push((prop.clone(), value.clone()));
        // 盒模型简写展开（margin/padding → 四长键）。同块内后续显式
        // 长键按文档序自然覆盖（declarations() 同 specificity 后者胜）
        if matches!(prop.as_str(), "margin" | "padding") {
            out.extend(expand_box_shorthand(&prop, &raw_value));
        }
    }
    out
}

/// 盒模型简写展开：1-4 值按 CSS 语义映射 top/right/bottom/left。
/// 值序列从原始文本重解析（`20% 0 0 auto` 整体不是合法单值，
/// parse_decl_value 会折叠成 Keyword）
fn expand_box_shorthand(prop: &str, raw: &str) -> Vec<(String, DeclValue)> {
    let raw = raw.strip_suffix("!important").map(str::trim).unwrap_or(raw);
    let parts: Vec<&str> = raw.split_whitespace().collect();
    if parts.is_empty() || parts.len() > 4 {
        return Vec::new();
    }
    let idx = match parts.len() {
        1 => [0, 0, 0, 0],
        2 => [0, 1, 0, 1],
        3 => [0, 1, 2, 1],
        _ => [0, 1, 2, 3],
    };
    let keys = ["-top", "-right", "-bottom", "-left"];
    let mut out = Vec::with_capacity(4);
    for (i, key) in keys.iter().enumerate() {
        let sub = format!("{}{}", prop, key);
        out.push((sub.clone(), parse_decl_value(&sub, parts[idx[i]])));
    }
    out
}

fn parse_decl_value(prop: &str, raw: &str) -> DeclValue {
    let v = raw.trim();
    let v = v.strip_suffix("!important").map(str::trim).unwrap_or(v);
    if v.is_empty() {
        return DeclValue::None;
    }
    let lower = v.to_ascii_lowercase();

    // background 简写：只关心其中的 url(...)（颜色/重复/定位关键字忽略）
    if prop == "background" || prop == "background-image" {
        return extract_url(v).map_or(DeclValue::None, DeclValue::Url);
    }
    if lower.starts_with("url(") {
        return extract_url(v).map_or(DeclValue::None, DeclValue::Url);
    }
    if let Some(num) = unit_value(v, "%") {
        return DeclValue::Percent(num);
    }
    if let Some(num) = unit_value(&lower, "px") {
        return DeclValue::Px(num);
    }
    if let Some(num) = unit_value(&lower, "em") {
        return DeclValue::Em(num);
    }
    if let Some(num) = unit_value(&lower, "pt") {
        return DeclValue::Pt(num);
    }
    DeclValue::Keyword(lower)
}

/// `100%` → Some(100.0)；非「数值+单位」形态返回 None
fn unit_value(v: &str, unit: &str) -> Option<f32> {
    v.strip_suffix(unit)?.trim().parse::<f32>().ok()
}

/// 提取 `url(...)` 内部地址并剥离引号（定位不依赖大小写与首位置，
/// 兼容 `background: #fff url(a.png) no-repeat` 简写形态）
fn extract_url(value: &str) -> Option<String> {
    let lower = value.to_ascii_lowercase();
    let start = lower.find("url(")? + 4;
    let end = lower[start..].find(')')? + start;
    let inner = value[start..end].trim();
    let inner = inner
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .or_else(|| inner.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
        .unwrap_or(inner);
    if inner.is_empty() {
        None
    } else {
        Some(inner.to_string())
    }
}

fn compound_matches(c: &CompoundSel, tag: &str, classes: &[String]) -> bool {
    if let Some(t) = &c.tag {
        if !t.eq_ignore_ascii_case(tag) {
            return false;
        }
    }
    c.classes.iter().all(|cl| classes.iter().any(|x| x == cl))
}

/// 末段匹配主体，其余段自近及远在祖先链上贪心回溯
/// （子代选择器不支持 ⇒ 无歧义回溯问题）
fn selector_matches(sel: &CssSelector, ctx: &NodeCtx) -> bool {
    let Some((subject, ancestors_sel)) = sel.compound.split_last() else {
        return false;
    };
    if !compound_matches(subject, &ctx.tag, &ctx.classes) {
        return false;
    }
    let mut anc_idx = ctx.ancestors.len();
    for c in ancestors_sel.iter().rev() {
        let mut found = false;
        while anc_idx > 0 {
            anc_idx -= 1;
            let (t, cs) = &ctx.ancestors[anc_idx];
            if compound_matches(c, t, cs) {
                found = true;
                break;
            }
        }
        if !found {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(tag: &str, classes: &[&str], ancestors: Vec<(&str, Vec<&str>)>) -> NodeCtx {
        NodeCtx {
            tag: tag.to_string(),
            classes: classes.iter().map(|s| s.to_string()).collect(),
            ancestors: ancestors
                .into_iter()
                .map(|(t, cs)| {
                    (
                        t.to_string(),
                        cs.into_iter().map(|s| s.to_string()).collect(),
                    )
                })
                .collect(),
        }
    }

    #[test]
    fn tag_class_and_descendant_matching() {
        let sheet = CssStylesheet::parse(
            "img.logo { width: 100%; }\ndiv.logo { text-align: center; }\nimg { width: 50%; }",
        );

        // div.logo > img.logo：三层上下文命中 img.logo{width:100%}
        let img_ctx = ctx(
            "img",
            &["logo"],
            vec![("html", vec![]), ("div", vec!["logo"])],
        );
        let decls = sheet.declarations(&img_ctx);
        assert_eq!(decls.get("width"), Some(&DeclValue::Percent(100.0)));

        // specificity：img.logo(1类) 击败 img(0类)
        assert_eq!(
            decls.get("width"),
            Some(&DeclValue::Percent(100.0)),
            "tag.class 必须击败纯 tag"
        );

        let div_ctx = ctx("div", &["logo"], vec![("html", vec![])]);
        assert_eq!(
            sheet.declarations(&div_ctx).get("text-align"),
            Some(&DeclValue::Keyword("center".into()))
        );

        // 无关上下文不命中 logo 规则
        let bare_img = ctx("img", &[], vec![]);
        assert_eq!(
            sheet.declarations(&bare_img).get("width"),
            Some(&DeclValue::Percent(50.0))
        );
    }

    #[test]
    fn body_class_background_url() {
        let sheet = CssStylesheet::parse(concat!(
            "body.qmp0 {\n",
            "    background-size: cover;\n",
            "    background-image: url('../Images/back1.jpg');\n",
            "}\n",
            "body.head {\n",
            "    background: #ffffff url(../Images/back03.jpg) no-repeat center;\n",
            "    background-size: 100%;\n",
            "}\n"
        ));

        let qmp0 = ctx("body", &["qmp0"], vec![]);
        let d = sheet.declarations(&qmp0);
        assert_eq!(
            d.get("background-image"),
            Some(&DeclValue::Url("../Images/back1.jpg".into()))
        );
        assert!(d.get("background-size").unwrap().is_keyword("cover"));

        // background 简写中的 url 与后续 background-size 覆盖
        let head = ctx("body", &["head"], vec![]);
        let d = sheet.declarations(&head);
        assert_eq!(
            d.get("background"),
            Some(&DeclValue::Url("../Images/back03.jpg".into()))
        );
        assert_eq!(
            d.get("background-size"),
            Some(&DeclValue::Percent(100.0))
        );
    }

    #[test]
    fn specificity_beats_order_and_order_beats_ties() {
        // 高 specificity 规则在文档序靠前：仍应胜出
        let sheet = CssStylesheet::parse("img.logo { width: 30%; } img { width: 50%; }");
        let c = ctx("img", &["logo"], vec![]);
        assert_eq!(
            sheet.declarations(&c).get("width"),
            Some(&DeclValue::Percent(30.0))
        );

        // 类数优先于标签数：img.logo(1类1标) 击败 .logo(1类0标)
        let sheet = CssStylesheet::parse("img.logo { width: 30%; } .logo { width: 60%; }");
        assert_eq!(
            sheet.declarations(&c).get("width"),
            Some(&DeclValue::Percent(30.0))
        );

        // 同 specificity：文档序靠后者胜出
        let sheet = CssStylesheet::parse("img.logo { width: 30%; } img.logo { width: 60%; }");
        assert_eq!(
            sheet.declarations(&c).get("width"),
            Some(&DeclValue::Percent(60.0))
        );
    }

    #[test]
    fn unsupported_syntax_skipped_gracefully() {
        let sheet = CssStylesheet::parse(concat!(
            "@charset \"utf-8\";\n",
            "@import url(\"fonts.css\");\n",
            "@media (min-width: 600px) { p { width: 999%; } }\n",
            "ruby > rt { font-size: 0.5em; }\n",
            "a[href]:hover { width: 88%; }\n",
            "p { margin-left:; text-shadow:; width: 75%; }\n",
            "/* 注释 */ span.num { height: 12px; }\n"
        ));
        let p = ctx("p", &[], vec![]);
        let d = sheet.declarations(&p);
        assert_eq!(d.get("width"), Some(&DeclValue::Percent(75.0)));
        // 空值声明保留为 None 而非误判
        assert_eq!(d.get("margin-left"), Some(&DeclValue::None));
        let rt = ctx("rt", &[], vec![("ruby", vec![])]);
        assert!(sheet.declarations(&rt).is_empty(), "子代选择器必须被跳过");
        let span = ctx("span", &["num"], vec![]);
        assert_eq!(
            sheet.declarations(&span).get("height"),
            Some(&DeclValue::Px(12.0))
        );
    }

    #[test]
    fn comma_group_and_units() {
        let sheet = CssStylesheet::parse(
            "h3, h4.head { margin: 1em; width: 90%; }\n.chubanshe { width: 100px; height: 24pt; }",
        );
        let h4 = ctx("h4", &["head"], vec![]);
        let d = sheet.declarations(&h4);
        assert_eq!(d.get("width"), Some(&DeclValue::Percent(90.0)));
        assert_eq!(d.get("margin"), Some(&DeclValue::Em(1.0)));

        let pub_logo = ctx("img", &["chubanshe"], vec![]);
        let d = sheet.declarations(&pub_logo);
        assert_eq!(d.get("width"), Some(&DeclValue::Px(100.0)));
        assert_eq!(d.get("height"), Some(&DeclValue::Pt(24.0)));
    }

    #[test]
    fn extend_merges_in_order() {
        let mut merged = CssStylesheet::parse("img { width: 50%; }");
        merged.extend(CssStylesheet::parse("img.logo { width: 100%; }"));
        let with_cls = ctx("img", &["logo"], vec![]);
        // 后合并的 img.logo spec 更高胜出
        assert_eq!(
            merged.declarations(&with_cls).get("width"),
            Some(&DeclValue::Percent(100.0))
        );
        let bare = ctx("img", &[], vec![]);
        assert_eq!(
            merged.declarations(&bare).get("width"),
            Some(&DeclValue::Percent(50.0))
        );
    }

    /// 盒模型简写展开：margin 四值/残缺形态，长键覆盖语义
    #[test]
    fn box_shorthand_expands_to_longhands() {
        let sheet = CssStylesheet::parse(concat!(
            "table.vol-title { margin: 20% 0 0 auto; }\n",
            "h2.head1 { padding: 0 4px; margin-top: 2em; margin: 10%; }\n"
        ));

        let td = ctx(
            "table",
            &["vol-title"],
            vec![],
        );
        let d = sheet.declarations(&td);
        assert_eq!(d.get("margin-top"), Some(&DeclValue::Percent(20.0)));
        assert_eq!(d.get("margin-left"), Some(&DeclValue::Keyword("auto".into())));
        assert_eq!(d.get("margin-bottom"), Some(&DeclValue::Keyword("0".into())));

        // 两值简写 + 同块内显式长键被后续简写覆盖（文档序后者胜）
        let h = ctx("h2", &["head1"], vec![]);
        let d = sheet.declarations(&h);
        assert_eq!(d.get("padding-top"), Some(&DeclValue::Keyword("0".into())));
        assert_eq!(d.get("padding-right"), Some(&DeclValue::Px(4.0)));
        assert_eq!(d.get("margin-top"), Some(&DeclValue::Percent(10.0)));
    }

    /// 《剑来》main.css 实录片段回归：duokan-* 私有属性、残缺值、嵌套注释块
    #[test]
    fn real_book_main_css_sample() {
        let css = r#"@charset "utf-8";
@import url("fonts.css");
body {
	padding: 0%;
	line-height: 130%;
	font-family: "DK-SONGTI", "st", "宋体", "zw", sans-serif;
}
div.logo {
    margin-top: 0em;
    text-align: center;
    duokan-bleed: lefttopright;
}
img.logo {
    width: 100%;
}
h2.head {
    font-size:1.05em;
	color: #2B3E5C;
	text-align: center;
}
table.vol-title td.vol-title-name {
  width: 1.2em;
  vertical-align: top;
}"#;
        let sheet = CssStylesheet::parse(css);

        let img = ctx(
            "img",
            &["logo"],
            vec![("html", vec![]), ("body", vec![]), ("div", vec!["logo"])],
        );
        let d = sheet.declarations(&img);
        assert_eq!(d.get("width"), Some(&DeclValue::Percent(100.0)));

        // 后代选择器三段命中 table.vol-title td.vol-title-name
        let td = ctx(
            "td",
            &["vol-title-name"],
            vec![
                ("html", vec![]),
                ("body", vec![]),
                ("table", vec!["vol-title"]),
                ("tr", vec![]),
            ],
        );
        assert_eq!(
            sheet.declarations(&td).get("width"),
            Some(&DeclValue::Em(1.2))
        );

        let h2 = ctx("h2", &["head"], vec![("body", vec![])]);
        assert_eq!(
            sheet.declarations(&h2).get("text-align"),
            Some(&DeclValue::Keyword("center".into()))
        );
    }
}
