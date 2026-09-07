//! A30b：EPUB 替换规则（用户净化规则）接入验证
//!
//! 三条红线：
//! 1. 展示生效——get_page_structured 返回「规则后文本」；
//! 2. 换规则重算——rules_hash 入结构化分页缓存键，规则变更即换键（若哈希
//!    不在键中，第二次调用会命中旧缓存返回规则 A 的结果）；
//! 3. 搜索对齐——search_in_book 命中「规则后文本」词，锚点经
//!    get_page_structured（同规则同参）定位的页面包含该词。搜索与展示
//!    同函数同时机应用规则（apply_replace_rules_to_blocks），锚点同源。

use bridge::api::*;
use bridge::PageInfo;
use std::io::Write;

fn page_text(p: &PageInfo) -> String {
    p.entries
        .iter()
        .filter_map(|e| e.text.as_deref())
        .collect()
}

/// 构造最小 EPUB（两章，均含将被规则替换的关键词「蓝鲸座」）
fn build_replace_epub(path: &std::path::Path) -> anyhow::Result<()> {
    let file = std::fs::File::create(path)?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::FileOptions::default();

    zip.start_file("mimetype", opts)?;
    zip.write_all(b"application/epub+zip")?;

    zip.start_file("META-INF/container.xml", opts)?;
    zip.write_all(
        br#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"#,
    )?;

    zip.start_file("OEBPS/content.opf", opts)?;
    zip.write_all(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">replace-test</dc:identifier>
    <dc:title>替换测试</dc:title>
    <dc:language>zh</dc:language>
    <meta property="dcterms:modified">2026-09-07T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/toc.ncx", opts)?;
    zip.write_all(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
  <head><meta name="dtb:uid" content="replace-test"/></head>
  <docTitle><text>替换测试</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>第二章</text></navLabel><content src="ch2.xhtml"/></navPoint>
  </navMap>
</ncx>"#
            .as_bytes(),
    )?;

    let ch = |title: &str, body: &str| {
        format!(
            r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{t}</title></head><body><p>{t}</p><p>{b}</p></body></html>"#,
            t = title,
            b = body
        )
    };
    let body1 = "这是第一章的正文内容，藏着独特关键词蓝鲸座。";
    let body2 = "第二章正文也提到蓝鲸座，还有普通句子。";

    zip.start_file("OEBPS/ch1.xhtml", opts)?;
    zip.write_all(ch("第一章 初入江湖", body1).as_bytes())?;
    zip.start_file("OEBPS/ch2.xhtml", opts)?;
    zip.write_all(ch("第二章 再遇强敌", body2).as_bytes())?;
    zip.finish()?;
    Ok(())
}

fn rule(pattern: &str, replacement: &str, enabled: bool) -> FfiReplaceRule {
    FfiReplaceRule {
        pattern: pattern.to_string(),
        replacement: replacement.to_string(),
        rule_type: 0, // 字符串直替
        enabled,
    }
}

/// 红线 1 + 2：展示路径应用规则；换规则即换缓存键重算
#[test]
fn epub_display_applies_replace_rules_and_recomputes_on_change() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    let dir = std::env::temp_dir().join(format!("a30b_rr_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("r.epub");
    build_replace_epub(&path).unwrap();
    let book_id =
        parse_txt_file(path.to_string_lossy().to_string(), None).expect("EPUB 导入失败");

    // 无规则：原文在位
    let page_none = get_page_structured(
        book_id.clone(), 0, 0,
        360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
        "TestFont".to_string(),
        None, 0, 0.9, true, 0,
        Vec::new(),
    )
    .expect("无规则取页失败");
    assert!(page_text(&page_none).contains("蓝鲸座"), "无规则时原文应在位");

    // 规则 A：蓝鲸座 → 甲甲甲甲
    let rules_a = vec![rule("蓝鲸座", "甲甲甲甲", true)];
    let page_a = get_page_structured(
        book_id.clone(), 0, 0,
        360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
        "TestFont".to_string(),
        None, 0, 0.9, true, 0,
        rules_a.clone(),
    )
    .expect("规则 A 取页失败");
    let text_a = page_text(&page_a);
    assert!(
        text_a.contains("甲甲甲甲"),
        "展示路径应应用规则（含替换结果），实际：{}",
        text_a
    );
    assert!(
        !text_a.contains("蓝鲸座"),
        "展示路径不得残留原文（规则后文本），实际：{}",
        text_a
    );

    // 红线 2：换规则 B（蓝鲸座 → 乙乙乙乙）。若 rules_hash 不在缓存键，
    // 此处会命中规则 A 的缓存返回「甲甲甲甲」
    let rules_b = vec![rule("蓝鲸座", "乙乙乙乙", true)];
    let page_b = get_page_structured(
        book_id.clone(), 0, 0,
        360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
        "TestFont".to_string(),
        None, 0, 0.9, true, 0,
        rules_b.clone(),
    )
    .expect("规则 B 取页失败");
    let text_b = page_text(&page_b);
    assert!(
        text_b.contains("乙乙乙乙") && !text_b.contains("甲甲甲甲"),
        "换规则必须换缓存键重算，实际：{}",
        text_b
    );

    // 禁用规则：等同无规则
    let rules_off = vec![rule("蓝鲸座", "甲甲甲甲", false)];
    let page_off = get_page_structured(
        book_id.clone(), 0, 0,
        360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
        "TestFont".to_string(),
        None, 0, 0.9, true, 0,
        rules_off,
    )
    .expect("禁用规则取页失败");
    assert!(
        page_text(&page_off).contains("蓝鲸座"),
        "禁用规则不得改写文本"
    );

    // 页数接口同参可调用（与页内容同键）
    let count = get_page_count_structured(
        book_id.clone(), 0,
        360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
        "TestFont".to_string(),
        0, 0.9, true, 0,
        rules_a,
    )
    .expect("带规则页数失败");
    assert!(count >= 1);

    let _ = std::fs::remove_dir_all(&dir);
}

/// 红线 3：搜索与展示同口径——search_in_book 在「规则后文本」上命中，
/// 锚点经同规则同参的 get_page_structured 定位落页含命中词
#[test]
fn epub_search_anchor_alignment_with_replace_rules() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    let dir = std::env::temp_dir().join(format!("a30b_align_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("a.epub");
    build_replace_epub(&path).unwrap();
    let book_id =
        parse_txt_file(path.to_string_lossy().to_string(), None).expect("EPUB 导入失败");

    let rules = vec![rule("蓝鲸座", "白鲸座", true)];

    // 原词在规则后文本中不存在 → 零命中（搜索确实应用了规则）
    let hits_orig = search_in_book(
        book_id.clone(),
        "蓝鲸座".into(),
        false, false, 0,
        rules.clone(),
        100,
    )
    .expect("原词搜索失败");
    assert!(
        hits_orig.is_empty(),
        "规则替换后原词不应命中：{:?}",
        hits_orig
    );

    // 规则后词命中：两章各一次
    let hits = search_in_book(
        book_id.clone(),
        "白鲸座".into(),
        false, false, 0,
        rules.clone(),
        100,
    )
    .expect("搜索失败");
    assert_eq!(hits.len(), 2, "两章应各命中一次：{:?}", hits);
    assert_eq!(hits[0].chapter_index, 0);
    assert_eq!(hits[1].chapter_index, 1);
    assert!(
        hits.iter().all(|h| h.excerpt.contains("白鲸座")),
        "摘录应基于规则后文本：{:?}",
        hits
    );

    // 锚点对齐：命中 anchor 经同规则展示路径定位的页面必须包含命中词
    for hit in &hits {
        let page = get_page_structured(
            book_id.clone(), hit.chapter_index, 0,
            360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
            "TestFont".to_string(),
            Some(hit.anchor_char_offset), 0, 0.9, true, 0,
            rules.clone(),
        )
        .expect("锚点定位取页失败");
        let text = page_text(&page);
        assert!(
            text.contains("白鲸座"),
            "anchor={} 定位页应包含规则后命中词，实际页文本：{}",
            hit.anchor_char_offset,
            text
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}
