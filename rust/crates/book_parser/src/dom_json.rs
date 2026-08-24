//! XHTML → JSON DOM（路线2 结构层）
//!
//! 用 html5ever（scraper）做容错解析——真实世界 XHTML 常为标签汤，
//! roxmltree 会硬性拒绝；实体已由解析器解码。输出紧凑 JSON：
//! 元素 `{"t":"p","a":{"class":"x"},"c":[...]}`，文本节点为裸字符串。
//! 语义分类/嵌套提取由 JS 规则层完成（D9），本模块只做结构化。
//!
//! 防护：递归深度帽 + 序列化尺寸帽（超限报错，调用方走纯文本兜底）。

use anyhow::{Context, Result};
use crate::content_cleaner::ConvertMode;
use scraper::{ElementRef, Html, Selector};
use serde_json::{json, Map, Value};

/// 跳过的标签（对内容提取无意义或体积噪声）
const SKIP_TAGS: [&str; 4] = ["script", "style", "template", "noscript"];
/// DOM 递归深度上限
pub const MAX_DEPTH: usize = 512;

/// 把 XHTML 解析为紧凑 JSON DOM Value（以 body 为根；无 body 则用根元素）。
/// 不做尺寸帽——由调用方在（可能的文本转换后）序列化时统一检查
pub fn xhtml_to_dom_json_value(html: &str) -> Result<Value> {
    let doc = Html::parse_document(html);

    let body_sel = Selector::parse("body")
        .map_err(|_| anyhow::anyhow!("内部错误：body 选择器无效"))?;
    let root_el = doc
        .select(&body_sel)
        .next()
        .or_else(|| {
            doc.root_element()
                .children()
                .find_map(ElementRef::wrap)
        });

    Ok(match root_el {
        Some(el) => element_to_value(el, 0),
        None => json!({"t": "div", "a": {}, "c": []}),
    })
}

/// 序列化 DOM JSON 并检查尺寸帽
pub fn serialize_dom_json(value: &Value, max_bytes: usize) -> Result<String> {
    let serialized = serde_json::to_string(value).context("DOM JSON 序列化失败")?;
    if serialized.len() > max_bytes {
        anyhow::bail!(
            "DOM JSON 超过大小上限: {} > {} bytes",
            serialized.len(),
            max_bytes
        );
    }
    Ok(serialized)
}

/// 把 XHTML 解析为紧凑 JSON DOM（字符串形态，含尺寸帽检查）
pub fn xhtml_to_dom_json(html: &str, max_bytes: usize) -> Result<String> {
    let value = xhtml_to_dom_json_value(html)?;
    serialize_dom_json(&value, max_bytes)
}

/// 就地转换 DOM 中全部文本节点（简繁转换；阅读级选项进结构化路径）。
///
/// 只遍历元素节点的 `"c"` 数组并转换其中的字符串（文本节点），
/// 属性（`"a"`）与标签名（`"t"`）不动——class/src/href 等语义字段
/// 必须保持原文。返回是否发生了任何替换。
///
/// 转换发生在 JS 提取（哨兵回收）之前：runs 字符区间在转换后文本上
/// 计算，天然对齐，不破坏 D10 契约（IR→布局零文本变换）。
pub fn convert_text_nodes(dom: &mut Value, mode: ConvertMode) -> bool {
    use crate::chinese_convert::{convert_s2t, convert_t2s};

    if matches!(mode, ConvertMode::None) {
        return false;
    }
    let convert = match mode {
        ConvertMode::None => return false,
        ConvertMode::SimplifiedToTraditional => convert_s2t as fn(&str) -> String,
        ConvertMode::TraditionalToSimplified => convert_t2s,
    };

    fn walk(node: &mut Value, convert: &fn(&str) -> String, changed: &mut bool) {
        match node {
            Value::Array(items) => {
                for item in items {
                    match item {
                        Value::String(s) => {
                            let converted = convert(s);
                            if converted != *s {
                                *s = converted;
                                *changed = true;
                            }
                        }
                        Value::Object(_) => walk(item, convert, changed),
                        _ => {}
                    }
                }
            }
            Value::Object(map) => {
                if let Some(children) = map.get_mut("c") {
                    walk(children, convert, changed);
                }
            }
            _ => {}
        }
    }

    let mut changed = false;
    walk(dom, &convert, &mut changed);
    changed
}

fn element_to_value(el: ElementRef, depth: usize) -> Value {
    let node = el.value();

    let mut attrs = Map::new();
    for (name, value) in node.attrs() {
        attrs.insert(name.to_string(), json!(value));
    }

    let children: Vec<Value> = if depth >= MAX_DEPTH {
        Vec::new()
    } else {
        el.children()
            .filter_map(|child| match child.value() {
                scraper::Node::Text(t) => {
                    let s = t.text.trim();
                    if s.is_empty() {
                        None
                    } else {
                        Some(json!(s))
                    }
                }
                scraper::Node::Element(e) => {
                    if SKIP_TAGS.contains(&e.name()) {
                        None
                    } else {
                        ElementRef::wrap(child).map(|wrapped| element_to_value(wrapped, depth + 1))
                    }
                }
                _ => None,
            })
            .collect()
    };

    json!({"t": node.name(), "a": attrs, "c": children})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_structure_and_text() {
        let html = r#"<html><head><title>t</title></head>
            <body><p class="x">第一段 <b>加粗</b>文本</p><img src="a.png" alt="图"/></body></html>"#;
        let dom = xhtml_to_dom_json(html, 1024 * 1024).unwrap();
        let v: Value = serde_json::from_str(&dom).unwrap();

        assert_eq!(v["t"], "body");
        let p = &v["c"][0];
        assert_eq!(p["t"], "p");
        assert_eq!(p["a"]["class"], "x");
        // 文本子节点是裸字符串，行内元素递归展开
        assert_eq!(p["c"][0], "第一段");
        assert_eq!(p["c"][1]["t"], "b");
        let img = &v["c"][1];
        assert_eq!(img["t"], "img");
        assert_eq!(img["a"]["src"], "a.png");
    }

    #[test]
    fn skips_script_style_and_comments() {
        let html = r#"<html><body><script>var x=1;</script>
            <style>.a{}</style><!-- 注释 -->正文</body></html>"#;
        let dom = xhtml_to_dom_json(html, 1024 * 1024).unwrap();
        assert!(!dom.contains("var x"));
        assert!(!dom.contains(".a{}"));
        assert!(dom.contains("正文"));
    }

    #[test]
    fn entities_pre_decoded() {
        let html = r#"<html><body><p>A &amp; B &#20013;</p></body></html>"#;
        let dom = xhtml_to_dom_json(html, 1024 * 1024).unwrap();
        assert!(dom.contains("A & B 中"));
    }

    #[test]
    fn size_cap_enforced() {
        let big = "x".repeat(10_000);
        let html = format!("<html><body><p>{}</p></body></html>", big);
        assert!(xhtml_to_dom_json(&html, 1024).is_err());
    }

    #[test]
    fn tag_soup_tolerated() {
        // 未闭合标签等真实世界脏 XHTML 应被 html5ever 容错处理
        let html = r#"<html><body><p>段落一<p>段落二<br>续行</body></html>"#;
        let dom = xhtml_to_dom_json(html, 1024 * 1024).unwrap();
        assert!(dom.contains("段落一"));
        assert!(dom.contains("续行"));
    }

    #[test]
    fn convert_text_nodes_only_touches_text() {
        // 简繁转换只动文本节点；属性（class/title/src）与标签名保持原文
        let html = r#"<html><body><p class="简" title="简体">简体乐园在幕后</p>
            <img src="简.png" alt="简体"/></body></html>"#;
        let mut v = xhtml_to_dom_json_value(html).unwrap();

        // 繁→简：文本本就是简体，无变化（幂等）
        assert!(!convert_text_nodes(&mut v, ConvertMode::TraditionalToSimplified));
        assert_eq!(v["c"][0]["a"]["class"], "简");

        // 简→繁：文本变化，属性不动
        let mut v2 = xhtml_to_dom_json_value(html).unwrap();
        assert!(convert_text_nodes(&mut v2, ConvertMode::SimplifiedToTraditional));
        let p = &v2["c"][0];
        assert_eq!(p["c"][0], "簡體樂園在幕後");
        assert_eq!(p["a"]["title"], "简体");
        assert_eq!(v2["c"][1]["a"]["src"], "简.png");
        assert_eq!(v2["c"][1]["a"]["alt"], "简体");
    }

    #[test]
    fn convert_none_is_noop() {
        let html = "<html><body><p>简体</p></body></html>";
        let mut v = xhtml_to_dom_json_value(html).unwrap();
        let before = v.clone();
        assert!(!convert_text_nodes(&mut v, ConvertMode::None));
        assert_eq!(v, before);
    }

    #[test]
    fn nested_inline_text_converted() {
        // 行内元素嵌套（runs 场景）：深层文本节点也要被转换
        let html = "<html><body><p>简体<span>乐园</span><b>幕后</b></p></body></html>";
        let mut v = xhtml_to_dom_json_value(html).unwrap();
        assert!(convert_text_nodes(&mut v, ConvertMode::SimplifiedToTraditional));
        let p = &v["c"][0];
        assert_eq!(p["c"][0], "簡體");
        assert_eq!(p["c"][1]["c"][0], "樂園");
        assert_eq!(p["c"][2]["c"][0], "幕後");
    }
}
