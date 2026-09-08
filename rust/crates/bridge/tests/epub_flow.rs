//! EPUB 阅读链路回归（债#1）：导入 → 章节列表 → 内容切片 → 分页
//!
//! 合成最小合法 EPUB（zip: mimetype + container.xml + opf + xhtml），
//! 验证 parse_txt_file 经工厂分发后与 TXT 同构可用。

use std::io::Write;

use bridge::api::*;
use bridge::PageInfo;

fn page_text(p: &PageInfo) -> String {
    p.entries
        .iter()
        .filter_map(|e| e.text.as_deref())
        .collect()
}

/// 页内文本行集合（含图页断言辅助）
fn page_texts(p: &PageInfo) -> Vec<String> {
    p.entries.iter().filter_map(|e| e.text.clone()).collect()
}

/// 构造最小 EPUB（两章）
fn build_minimal_epub(path: &std::path::Path) -> anyhow::Result<()> {
    let file = std::fs::File::create(path)?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::FileOptions::default();

    // mimetype 必须首个且不压缩（规范要求；读取器宽容，这里仍遵守）
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
    <dc:identifier id="uid">test-epub</dc:identifier>
    <dc:title>测试EPUB</dc:title>
    <dc:language>zh</dc:language>
    <meta property="dcterms:modified">2026-08-22T00:00:00Z</meta>
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
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-epub"/></head>
  <docTitle><text>测试EPUB</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>第一章 初入江湖</text></navLabel>
      <content src="ch1.xhtml"/>
    </navPoint>
    <navPoint id="n2" playOrder="2">
      <navLabel><text>第二章 再遇强敌</text></navLabel>
      <content src="ch2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>"#
            .as_bytes(),
    )?;

    let ch = |title: &str, body: String| {
        format!(
            r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{t}</title></head>
<body><h2>{t}</h2><p>{b}</p></body></html>"#,
            t = title,
            b = body
        )
    };
    let body1 = "主角在山中修行，一日千里。".repeat(30);
    let body2 = "敌人出现在深夜的巷口，杀意凛然。".repeat(30);

    zip.start_file("OEBPS/ch1.xhtml", opts)?;
    zip.write_all(ch("第一章 初入江湖", body1).as_bytes())?;
    zip.start_file("OEBPS/ch2.xhtml", opts)?;
    zip.write_all(ch("第二章 再遇强敌", body2).as_bytes())?;

    zip.finish()?;
    Ok(())
}

/// 路线2 切换后端到端：导入轻句柄 → 章节表 → 结构化分页（文本可见、双章不串）
#[test]
fn epub_import_and_read_end_to_end() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    let dir = std::env::temp_dir().join(format!("epub_flow_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("test.epub");
    build_minimal_epub(&path).unwrap();

    // 1. 导入（EPUB 分支为轻句柄：章节表完整，不再物化全文）
    let book_id =
        parse_txt_file(path.to_string_lossy().to_string(), None).expect("EPUB 导入失败");

    // 2. 格式分流标记
    assert_eq!(get_book_format(book_id.clone()).unwrap(), "epub");

    // 3. 章节列表
    let chapters = get_chapters(book_id.clone()).unwrap();
    assert_eq!(chapters.len(), 2, "应识别出 spine 中的 2 章");
    assert_eq!(chapters[0].title, "第一章 初入江湖");

    // 4. 结构化分页：正文可见且双章互不串
    let args = (
        360.0f32, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
    );
    let count = get_page_count_structured(
        book_id.clone(),
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("结构化分页计数失败");
    assert!(count >= 1, "至少一页");

    let page = get_page_structured(
        book_id.clone(),
        0,
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        None,
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("结构化分页失败");
    assert!(
        page_text(&page).contains("山中修行"),
        "第 1 章正文应在位"
    );
    assert!(
        !page_text(&page).contains("深夜的巷口"),
        "第 1 章不得混入第 2 章"
    );

    let page_ch2 = get_page_structured(
        book_id.clone(),
        1,
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        None,
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("结构化分页失败");
    assert!(page_text(&page_ch2).contains("深夜的巷口"), "第 2 章正文应在位");

    // 5. 锚点定位：超界锚点收敛到末页
    let last = get_page_structured(
        book_id,
        0,
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        Some(usize::MAX),
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("锚点定位失败");
    assert!(!page_text(&last).is_empty() || count == 1);

    let _ = std::fs::remove_dir_all(&dir);
}

/// 构造带广告文本的最小 EPUB（单章，供净化缓存测试）
fn build_ad_epub(path: &std::path::Path) -> anyhow::Result<()> {
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
    <dc:title>广告书</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="ch1"/></spine>
</package>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/toc.ncx", opts)?;
    zip.write_all(
        r#"<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1"><navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/></navPoint>
  </navMap>
</ncx>"#
            .as_bytes(),
    )?;

    let body = format!(
        "{}<img src=\"images/pic.png\" alt=\"插图\"/>{}本书由笔趣阁首发，请记住本站 www.biquge.com{}",
        "正文内容连续叙述。".repeat(10),
        "后续情节展开。".repeat(10),
        "结尾段落收束全文。".repeat(5)
    );
    zip.start_file("OEBPS/ch1.xhtml", opts)?;
    zip.write_all(
        format!(
            r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
<body><h2>第一章</h2><p>{}</p></body></html>"#,
            body
        )
        .as_bytes(),
    )?;

    zip.finish()?;
    Ok(())
}

/// 路线2 切换后：去广告能力在结构化提取层保留（与净化规则单一来源共享），
/// 图片块照常产出
#[test]
fn epub_structured_ad_filtering() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    let dir = std::env::temp_dir().join(format!("epub_clean_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("ad.epub");
    build_ad_epub(&path).unwrap();

    // 无需设置净化选项：广告过滤内置于结构化提取
    let book_id =
        parse_txt_file(path.to_string_lossy().to_string(), None).expect("EPUB 导入失败");

    let args = (360.0f32, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0);
    let count = get_page_count_structured(
        book_id.clone(),
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("结构化分页计数失败");

    let mut all_text = String::new();
    let mut has_image = false;
    for i in 0..count {
        let page = get_page_structured(
            book_id.clone(),
            0,
            i,
            args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
            "TestFont".to_string(),
            None,
            0, 0.9, true, 0, false, Vec::new(),
        )
        .expect("结构化分页失败");
        all_text.push_str(&page_text(&page));
        if page.entries.iter().any(|e| e.resource_href.is_some()) {
            has_image = true;
        }
    }

    assert!(all_text.contains("正文内容"), "正常正文应在位");
    assert!(all_text.contains("后续情节"), "广告后的正文应保留");
    assert!(!all_text.contains("笔趣阁"), "广告站名应在提取层被清除");
    assert!(!all_text.contains("biquge.com"), "广告域名应在提取层被清除");
    assert!(has_image, "图片块不应丢失");

    let _ = std::fs::remove_dir_all(&dir);
}

/// 构造嵌套目录 EPUB（vol1 > ch1/ch2 两级 TOC，spine 顺序 卷→章→章）
fn build_nested_toc_epub(path: &std::path::Path) -> anyhow::Result<()> {
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
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>卷章书</dc:title></metadata>
  <manifest>
    <item id="vol1" href="vol1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="vol1"/><itemref idref="ch1"/><itemref idref="ch2"/></spine>
</package>"#
            .as_bytes(),
    )?;

    // NCX 嵌套：v1 下挂 c1/c2；src 相对 toc.ncx（OEBPS/）解析，ch 在 text/ 子目录
    zip.start_file("OEBPS/toc.ncx", opts)?;
    zip.write_all(
        r#"<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="v1"><navLabel><text>第一卷</text></navLabel><content src="vol1.xhtml"/>
      <navPoint id="c1"><navLabel><text>第一章</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
      <navPoint id="c2"><navLabel><text>第二章</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
    </navPoint>
  </navMap>
</ncx>"#
            .as_bytes(),
    )?;

    let body = "卷章正文内容。".repeat(10);
    let ch = |t: &str| {
        format!(
            r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{t}</title></head><body><h2>{t}</h2><p>{b}</p></body></html>"#,
            t = t,
            b = body
        )
    };
    zip.start_file("OEBPS/vol1.xhtml", opts)?;
    zip.write_all(ch("第一卷").as_bytes())?;
    zip.start_file("OEBPS/text/ch1.xhtml", opts)?;
    zip.write_all(ch("第一章").as_bytes())?;
    zip.start_file("OEBPS/text/ch2.xhtml", opts)?;
    zip.write_all(ch("第二章").as_bytes())?;

    zip.finish()?;
    Ok(())
}

/// M0 回归：OPF 位于 OEBPS/ 子目录时 TOC 标题必须命中
/// （旧实现用「TOC 相对键 .starts_with(spine 全路径)」方向反了，永不匹配）
#[test]
fn epub_toc_titles_resolved_in_subdir() {
    let dir = std::env::temp_dir().join(format!("epub_title_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("t.epub");
    build_minimal_epub(&path).unwrap();

    let book_id = parse_txt_file(path.to_string_lossy().to_string(), None).unwrap();
    let chapters = get_chapters(book_id).unwrap();

    assert_eq!(chapters.len(), 2);
    assert_eq!(chapters[0].title, "第一章 初入江湖", "子目录 TOC 标题应命中");
    assert_eq!(chapters[1].title, "第二章 再遇强敌");

    // 平铺书：层级恒为 1、无父章节
    assert_eq!(chapters[0].level, 1);
    assert!(chapters[0].parent_index.is_none());

    let _ = std::fs::remove_dir_all(&dir);
}

/// 嵌套 TOC：层级与父索引按 spine 序透传到 FFI；相对路径 src 按目录解析
#[test]
fn epub_nested_toc_hierarchy() {
    let dir = std::env::temp_dir().join(format!("epub_nest_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("n.epub");
    build_nested_toc_epub(&path).unwrap();

    let book_id = parse_txt_file(path.to_string_lossy().to_string(), None).unwrap();
    let chapters = get_chapters(book_id).unwrap();

    let titles: Vec<&str> = chapters.iter().map(|c| c.title.as_str()).collect();
    assert_eq!(titles, vec!["第一卷", "第一章", "第二章"]);

    let levels: Vec<u8> = chapters.iter().map(|c| c.level).collect();
    assert_eq!(levels, vec![1, 2, 2]);

    let parents: Vec<Option<usize>> = chapters.iter().map(|c| c.parent_index).collect();
    assert_eq!(parents, vec![None, Some(0), Some(0)], "父=最近的前一条严格更浅章节");

    let _ = std::fs::remove_dir_all(&dir);
}

/// M2 探针：结构化 IR v2 提取（StructuredContent 包装；标题/段落/图片块），
/// 图片路径已按内容文件目录解析，anc 中间字段已剥离
#[test]
fn epub_structured_probe() {
    let dir = std::env::temp_dir().join(format!("epub_ir_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("s.epub");
    build_ad_epub(&path).unwrap();

    let json = epub_chapter_structured(path.to_string_lossy().to_string(), 0)
        .expect("结构化探针失败");
    let v: serde_json::Value = serde_json::from_str(&json).expect("IR 应为合法 JSON");
    assert_eq!(v["version"], 2, "应为 IR v2 包装");
    assert!(v.get("background").map_or(true, |b| b.is_null()), "无背景书不应产出背景");
    let blocks = v["blocks"].as_array().expect("blocks 应为数组");

    assert!(!blocks.is_empty(), "不应为空");
    assert_eq!(blocks[0]["type"], "heading", "首块应为 h2 标题");
    assert_eq!(blocks[0]["level"], 2);

    let texts: Vec<&str> = blocks
        .iter()
        .filter(|b| b["type"] == "paragraph")
        .filter_map(|b| b["text"].as_str())
        .collect();
    assert!(
        texts.iter().any(|t| t.contains("正文内容")),
        "段落文本应在位"
    );

    // 图片块：raw src 已按内容文件所在目录（OEBPS/）解析为 ZIP 全路径
    let img = blocks
        .iter()
        .find(|b| b["type"] == "image")
        .expect("应含图片块");
    assert_eq!(img["resource_href"], "OEBPS/images/pic.png");
    assert_eq!(img["alt"], "插图");
    // anc 为 JS 层中间字段，交付前必须剥离
    assert!(img.get("anc").is_none() || img["anc"].is_null(), "anc 必须已剥离");

    let _ = std::fs::remove_dir_all(&dir);
}

/// 构造含行内字形标记的最小 EPUB（strong/em/a/span.bl + 外链 CSS）
fn build_glyph_epub(path: &std::path::Path) -> anyhow::Result<()> {
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
    <dc:title>字形书</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="styles.css" media-type="text/css"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="ch1"/></spine>
</package>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/toc.ncx", opts)?;
    zip.write_all(
        r#"<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1"><navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/></navPoint>
  </navMap>
</ncx>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/styles.css", opts)?;
    zip.write_all(b"span.bl { font-weight: bold; }")?;

    zip.start_file("OEBPS/ch1.xhtml", opts)?;
    zip.write_all(
        r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title>
<link rel="stylesheet" type="text/css" href="styles.css"/></head>
<body><h2>第一章</h2>
<p>甲<strong>粗</strong>乙<em>斜</em>丙<a>链</a>丁<span class="bl">类粗</span>尾</p>
</body></html>"#
            .as_bytes(),
    )?;

    zip.finish()?;
    Ok(())
}

/// M5 探针：行内字形物化——标签默认语义（strong/em/a）+ CSS 类覆盖，
/// IR JSON 的 runs 携带 bold/italic/underline
#[test]
fn epub_glyph_runs_probe() {
    let dir = std::env::temp_dir().join(format!("epub_glyph_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("g.epub");
    build_glyph_epub(&path).unwrap();

    let json = epub_chapter_structured(path.to_string_lossy().to_string(), 0)
        .expect("结构化探针失败");
    let v: serde_json::Value = serde_json::from_str(&json).expect("IR 应为合法 JSON");
    let blocks = v["blocks"].as_array().expect("blocks 应为数组");
    let para = blocks
        .iter()
        .find(|b| b["type"] == "paragraph")
        .expect("应含段落块");
    assert_eq!(para["text"], "甲粗乙斜丙链丁类粗尾");

    let runs = para["runs"].as_array().expect("runs 应为数组");
    assert_eq!(runs.len(), 4, "应有 4 个样式区段（strong/em/a/span.bl）");

    // 探针返回物化后 IR（anc 已剥离），以字符区间识别区段归属：
    // 甲(0) 粗(1) 乙(2) 斜(3) 丙(4) 链(5) 丁(6) 类粗(7..9) 尾(9)
    // （false 字段被 skip 序列化，读取为 Null）
    assert_eq!(runs[0]["start"], 1);
    assert_eq!(runs[0]["end"], 2);
    assert_eq!(runs[0]["bold"], true, "strong → 粗体");
    assert!(runs[0]["italic"].is_null());

    assert_eq!(runs[1]["start"], 3);
    assert_eq!(runs[1]["end"], 4);
    assert!(runs[1]["bold"].is_null());
    assert_eq!(runs[1]["italic"], true, "em → 斜体");

    assert_eq!(runs[2]["start"], 5);
    assert_eq!(runs[2]["end"], 6);
    assert_eq!(runs[2]["underline"], true, "a → 下划线");

    assert_eq!(runs[3]["start"], 7);
    assert_eq!(runs[3]["end"], 9);
    assert_eq!(runs[3]["bold"], true, "CSS font-weight:bold 应物化到 span.bl");

    let _ = std::fs::remove_dir_all(&dir);
}

/// 构造含 ruby 注音的最小 EPUB（单章）
fn build_ruby_epub(path: &std::path::Path) -> anyhow::Result<()> {
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
    <dc:title>注音书</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="ch1"/></spine>
</package>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/toc.ncx", opts)?;
    zip.write_all(
        r#"<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1"><navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/></navPoint>
  </navMap>
</ncx>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/ch1.xhtml", opts)?;
    zip.write_all(
        r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
<body><h2>第一章</h2>
<p>见<ruby>漢<rp>(</rp><rt>han</rt></ruby>字成句</p>
</body></html>"#
            .as_bytes(),
    )?;

    zip.finish()?;
    Ok(())
}

/// M5 探针：ruby 注音——rp 丢弃、rt 独立 run 且默认小字号倍率、
/// 基字与注音留在同一段落
#[test]
fn epub_ruby_probe() {
    let dir = std::env::temp_dir().join(format!("epub_ruby_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("r.epub");
    build_ruby_epub(&path).unwrap();

    let json = epub_chapter_structured(path.to_string_lossy().to_string(), 0)
        .expect("结构化探针失败");
    let v: serde_json::Value = serde_json::from_str(&json).expect("IR 应为合法 JSON");
    let blocks = v["blocks"].as_array().expect("blocks 应为数组");

    // rp 括号必须消失；基字/注音/后字同段连续
    let texts: Vec<&str> = blocks
        .iter()
        .filter(|b| b["type"] == "paragraph")
        .filter_map(|b| b["text"].as_str())
        .collect();
    assert!(
        texts.iter().any(|t| *t == "见漢han字成句"),
        "基字与注音应在同一段落且 rp 丢弃，实际: {:?}",
        texts
    );

    let para = blocks
        .iter()
        .find(|b| b["type"] == "paragraph" && b["text"] == "见漢han字成句")
        .expect("应含注音段落");
    let runs = para["runs"].as_array().expect("runs 应为数组");
    assert_eq!(runs.len(), 1, "只有 rt 一个样式区段");
    assert_eq!(runs[0]["start"], 2);
    assert_eq!(runs[0]["end"], 5);
    assert_eq!(
        runs[0]["font_scale"], 0.5,
        "rt 默认小字倍率"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// 构造含小表格的最小 EPUB（单章，2 列 × 2 行）
fn build_table_epub(path: &std::path::Path) -> anyhow::Result<()> {
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
    <dc:title>表书</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="ch1"/></spine>
</package>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/toc.ncx", opts)?;
    zip.write_all(
        r#"<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1"><navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/></navPoint>
  </navMap>
</ncx>"#
            .as_bytes(),
    )?;

    zip.start_file("OEBPS/ch1.xhtml", opts)?;
    zip.write_all(
        r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
<body><h2>第一章</h2>
<table><tr><td>甲一</td><td>乙二</td></tr><tr><td>丙三</td><td>丁四</td></tr></table>
<p>表后续段。</p>
</body></html>"#
            .as_bytes(),
    )?;

    zip.finish()?;
    Ok(())
}

/// M5 探针：表格线框经 FFI 全链透传——页内出现 is_table_frame 条目，
/// 几何为正数；文本条目 is_table_frame 恒 false
#[test]
fn epub_table_frame_probe() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    let dir = std::env::temp_dir().join(format!("epub_tbl_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("t.epub");
    build_table_epub(&path).unwrap();

    let book_id =
        parse_txt_file(path.to_string_lossy().to_string(), None).expect("EPUB 导入失败");

    let args = (360.0f32, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0);
    let count = get_page_count_structured(
        book_id.clone(),
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("结构化分页计数失败");
    assert!(count >= 1);

    let mut frame_count = 0usize;
    for i in 0..count {
        let page = get_page_structured(
            book_id.clone(),
            0,
            i,
            args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
            "TestFont".to_string(),
            None,
            0, 0.9, true, 0, false, Vec::new(),
        )
        .expect("结构化分页失败");
        for e in &page.entries {
            if e.is_table_frame {
                frame_count += 1;
                assert!(e.width > 0.0 && e.height > 0.0, "线框几何必须为正");
                assert!(e.text.is_none(), "线框条目不携带文本");
            } else if let Some(t) = &e.text {
                assert!(!t.is_empty());
            }
        }
    }
    assert_eq!(frame_count, 4, "应有 4 个单元格线框（2 行 × 2 列）");

    let _ = std::fs::remove_dir_all(&dir);
}

/// M6 探针：EPUB 翻章预取——前台持锁让路、幂等秒回、预热后前台命中、参数隔离
#[test]
fn epub_prefetch_structured_chapter() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    let dir = std::env::temp_dir().join(format!("epub_pf_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("p.epub");
    build_minimal_epub(&path).unwrap();

    let book_id =
        parse_txt_file(path.to_string_lossy().to_string(), None).expect("EPUB 导入失败");

    let args = (360.0f32, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0);

    // 前台先读 ch0（建立书状态与缓存基线）
    let count0 = get_page_count_structured(
        book_id.clone(),
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("ch0 计数失败");
    assert!(count0 >= 1);

    // 前台持 BOOKS 写锁 → 预取让路返回 false（try_write 失败即放弃，
    // 不阻塞前台——std RwLock 非重入但 try_write 永不阻塞，同线程安全）
    {
        let _guard = bridge::BOOKS.write().unwrap();
        assert!(
            !prefetch_structured_chapter(
                book_id.clone(),
                1,
                args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
                "TestFont".to_string(),
                0, 0.9, true, 0, false, Vec::new(),
            )
            .expect("锁忙预取不应报错"),
            "前台持锁时预取应让路返回 false"
        );
    }

    // 锁释放后预取 ch1：真实提取入缓存。
    // （并行测试会争用全局 BOOKS 锁，可能瞬时让路——重试直至成功）
    let mut warmed = false;
    for _ in 0..100 {
        if prefetch_structured_chapter(
            book_id.clone(),
            1,
            args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
            "TestFont".to_string(),
            0, 0.9, true, 0, false, Vec::new(),
        )
        .expect("预取不应报错")
        {
            warmed = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(warmed, "锁释放后预取应最终成功");

    // 幂等：再次预取键已存在秒回 true
    assert!(
        prefetch_structured_chapter(
            book_id.clone(),
            1,
            args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
            "TestFont".to_string(),
            0, 0.9, true, 0, false, Vec::new(),
        )
        .expect("幂等预取失败")
    );

    // 预热后前台读取 ch1 内容正确（缓存命中路径）
    let page_ch1 = get_page_structured(
        book_id.clone(),
        1,
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        None,
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("ch1 前台读取失败");
    assert!(page_text(&page_ch1).contains("深夜的巷口"), "第 2 章正文应在位");

    // 参数隔离：不同 convert_mode 是不同键，各自预取/读取互不干扰
    let mut warmed_s2t = false;
    for _ in 0..100 {
        if prefetch_structured_chapter(
            book_id.clone(),
            1,
            args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
            "TestFont".to_string(),
            1, 0.9, true, 0, false, Vec::new(),
        )
        .expect("convert=1 预取不应报错")
        {
            warmed_s2t = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(warmed_s2t, "convert=1 预取应最终成功");
    let count_s2t = get_page_count_structured(
        book_id.clone(),
        1,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        1, 0.9, true, 0, false, Vec::new(),
    )
    .expect("convert=1 计数失败");
    assert!(count_s2t >= 1);
    // 原模式缓存不受影响
    let page_again = get_page_structured(
        book_id.clone(),
        1,
        0,
        args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7,
        "TestFont".to_string(),
        None,
        0, 0.9, true, 0, false, Vec::new(),
    )
    .expect("原模式回读失败");
    assert!(page_text(&page_again).contains("深夜的巷口"));

    let _ = std::fs::remove_dir_all(&dir);
}

/// M2/M3 真书探针（#[ignore]）：EBOOK_PROBE_PATH 指向真实 EPUB，
/// 打印抽样章 IR 摘要（背景/块样式/图片物化），并全量扫描统计
/// 文字样式与表格物化的命中情况
#[test]
#[ignore]
fn real_book_structured_probe() {
    use book_parser::BookParser;

    let Ok(path) = std::env::var("EBOOK_PROBE_PATH") else {
        panic!("请设置 EBOOK_PROBE_PATH 指向真实 EPUB");
    };
    let mut parser = book_parser::EpubParser::from_file(std::path::Path::new(&path))
        .expect("EPUB 打开失败");
    parser.parse().expect("EPUB 解析失败");
    let chapters = parser.get_chapter_list().unwrap();

    println!("总章数: {}", chapters.len());

    // 全量扫描：样式命中统计
    let mut styled_para = 0usize;
    let mut para_with_runs = 0usize;
    let mut styled_heading = 0usize;
    let mut tables = 0usize;
    let mut table_with_margin = 0usize;
    let mut cells_with_width = 0usize;
    let mut sample_hits: Vec<String> = Vec::new();
    for idx in 0..chapters.len() {
        let Ok(content) = parser.get_chapter_content_structured(idx) else {
            continue;
        };
        let mut hit_desc: Option<String> = None;
        for block in &content.blocks {
            match block {
                book_parser::ContentBlock::Paragraph { text, align, color, font_scale, runs, .. } => {
                    if color.is_some() || font_scale.is_some() || align.is_some() {
                        styled_para += 1;
                        if hit_desc.is_none() && !text.is_empty() {
                            hit_desc = Some(format!(
                                "para color={:?} scale={:?} align={:?} 「{}」",
                                color,
                                font_scale,
                                align,
                                &text.chars().take(12).collect::<String>()
                            ));
                        }
                    }
                    if !runs.is_empty() {
                        para_with_runs += 1;
                        if hit_desc.is_none() {
                            hit_desc = Some(format!(
                                "runs={} 首段色={:?}「{}」",
                                runs.len(),
                                runs[0].color,
                                &text.chars().take(10).collect::<String>()
                            ));
                        }
                    }
                }
                book_parser::ContentBlock::Heading { level, text, align, color, font_scale, .. } => {
                    if color.is_some() || font_scale.is_some() || align.is_some() {
                        styled_heading += 1;
                        if hit_desc.is_none() {
                            hit_desc = Some(format!(
                                "h{}{} color={:?} scale={:?}「{}」",
                                level,
                                "",
                                color,
                                font_scale,
                                &text.chars().take(12).collect::<String>()
                            ));
                        }
                    }
                }
                book_parser::ContentBlock::Table { rows, margin_top_percent, .. } => {
                    tables += 1;
                    if margin_top_percent.is_some() {
                        table_with_margin += 1;
                    }
                    for row in rows {
                        for cell in row {
                            if cell.width_em.is_some() {
                                cells_with_width += 1;
                            }
                        }
                    }
                    if hit_desc.is_none() {
                        hit_desc = Some(format!(
                            "table 行数={} margin%={:?} 列宽em={:?}",
                            rows.len(),
                            margin_top_percent,
                            rows.first().and_then(|r| r.first()).and_then(|c| c.width_em)
                        ));
                    }
                }
                _ => {}
            }
        }
        if let Some(desc) = hit_desc {
            if sample_hits.len() < 8 {
                sample_hits.push(format!("[{}] {} → {}", idx, chapters[idx].title, desc));
            }
        }
    }
    println!(
        "=== 全量扫描 ===\n带样式段落={} 带runs段落={} 带样式标题={} 表格={} 含margin表格={} 含列宽单元格={}",
        styled_para, para_with_runs, styled_heading, tables, table_with_margin, cells_with_width
    );
    for h in &sample_hits {
        println!("样例 {}", h);
    }

    // 抽样章详细块转储
    let sample = [0usize, 1, 4, 16, 100];
    for idx in sample {
        if idx >= chapters.len() {
            continue;
        }
        let content = parser
            .get_chapter_content_structured(idx)
            .unwrap_or_else(|e| panic!("章节 {} 提取失败: {}", idx, e));
        println!(
            "--- [{}] {} | 背景={:?} body_classes={:?} 块数={}",
            idx,
            chapters[idx].title,
            content
                .background
                .as_ref()
                .map(|b| (&b.image_href, b.size)),
            content.body_classes,
            content.blocks.len()
        );
        for (i, block) in content.blocks.iter().take(4).enumerate() {
            match block {
                book_parser::ContentBlock::Image {
                    resource_href,
                    width_percent,
                    align,
                    intrinsic,
                    bleed,
                    ..
                } => println!(
                    "  [{}] image href={} width%={:?} align={:?} intrinsic={:?} bleed={}",
                    i, resource_href, width_percent, align, intrinsic, bleed
                ),
                book_parser::ContentBlock::Paragraph { text, align, color, font_scale, runs, .. } => {
                    println!(
                        "  [{}] para align={:?} color={:?} scale={:?} runs={} 「{}…」",
                        i,
                        align,
                        color,
                        font_scale,
                        runs.len(),
                        &text.chars().take(18).collect::<String>()
                    );
                    for r in runs.iter().take(3) {
                        println!(
                            "      run[{}..{}] color={:?} scale={:?}",
                            r.start, r.end, r.color, r.font_scale
                        );
                    }
                }
                book_parser::ContentBlock::Heading { level, text, align, color, font_scale, .. } => println!(
                    "  [{}] h{} align={:?} color={:?} scale={:?} 「{}」",
                    i, level, align, color, font_scale, text
                ),
                book_parser::ContentBlock::Table { rows, margin_top_percent, .. } => {
                    println!(
                        "  [{}] table 行数={} margin%={:?}",
                        i,
                        rows.len(),
                        margin_top_percent
                    );
                    for (ri, row) in rows.iter().take(2).enumerate() {
                        for cell in row.iter().take(3) {
                            let cell_text = cell
                                .blocks
                                .iter()
                                .filter_map(|b| match b {
                                    book_parser::ContentBlock::Paragraph { text, align, color, font_scale, .. } => Some(
                                        format!("{}/{:?}/{:?}/{:?}", text.chars().take(6).collect::<String>(), align, color, font_scale)
                                    ),
                                    _ => None,
                                })
                                .collect::<Vec<_>>()
                                .join("|");
                            println!(
                                "      r{} header={} w_em={:?} → {}",
                                ri, cell.header, cell.width_em, cell_text
                            );
                        }
                    }
                }
                other => println!("  [{}] {:?}", i, other),
            }
        }
    }
}
