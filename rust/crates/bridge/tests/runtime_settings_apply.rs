//! 运行时设置即时生效验证（无需重启、无需重建书籍）：
//! 1. 简繁切换：chinese_convert 变更后 get_page_processed 立即返回转换后文本
//! 2. 替换规则：规则随请求传入立即生效
//! 3. 缓存隔离：不同选项的缓存互不污染

use bridge::api::*;
use bridge::PageInfo;

fn page_text(p: &PageInfo) -> String {
    p.entries
        .iter()
        .filter_map(|e| e.text.as_deref())
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn call(book_id: &str, convert: u8, rules: Vec<FfiReplaceRule>) -> PageInfo {
    get_page_processed(
        book_id.to_string(),
        0,
        0,
        360.0,
        640.0,
        18.0,
        1.5,
        20.0,
        20.0,
        20.0,
        20.0,
        "TestFont".to_string(),
        true,
        false,
        convert,
        rules,
        None,
        0.9,
    )
    .expect("get_page_processed failed")
}

#[test]
fn runtime_convert_and_rules_apply_immediately() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    // 构造测试书：简体内容，含可替换词
    let dir = std::env::temp_dir().join(format!("rt_settings_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("book.txt");
    let body = "主角武圣正在读书写字，他喜欢读书。\n".repeat(50);
    std::fs::write(&path, format!("第一章 测试\n{}", body)).unwrap();

    let book_id = parse_txt_file(path.to_string_lossy().to_string(), None).unwrap();

    // 基线：无转换
    let t_base = page_text(&call(&book_id, 0, vec![]));
    assert!(t_base.contains('读'), "基线应含简体'读'");

    // 简转繁：立即生效
    let t_s2t = page_text(&call(&book_id, 1, vec![]));
    assert!(t_s2t != t_base, "s2t 后文本必须变化");
    assert!(
        t_s2t.contains('讀') || t_s2t.contains('書') || t_s2t.contains('寫'),
        "应含繁体字符"
    );
    assert!(!t_s2t.contains('读'), "不应再含简体'读'");

    // 替换规则：立即生效
    let rules = vec![FfiReplaceRule {
        pattern: "武圣".into(),
        replacement: "李明".into(),
        rule_type: 0,
        enabled: true,
    }];
    let t_ruled = page_text(&call(&book_id, 0, rules));
    assert!(t_ruled.contains("李明"), "替换规则应生效");
    assert!(!t_ruled.contains("武圣"), "原词应被替换");

    // 缓存隔离：切回无转换，内容恢复基线
    let t_back = page_text(&call(&book_id, 0, vec![]));
    assert_eq!(t_back, t_base, "切回选项后应恢复基线内容");

    let _ = std::fs::remove_dir_all(&dir);
}

/// 完整模拟应用真实序列：
/// openBook(带净化解析) → 应用设置(update_book_cleaning) → 带锚点加载(含规则)
#[test]
fn app_flow_rules_apply_after_update_book_cleaning() {
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

    let dir = std::env::temp_dir().join(format!("rt_appflow_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("book.txt");
    let body = "主角武圣正在读书写字，他喜欢读书。\n".repeat(50);
    std::fs::write(&path, format!("第一章 测试\n{}", body)).unwrap();

    // 1. openBook：带净化选项解析（与 buildCleaningOptions 默认值一致）
    let book_id = parse_txt_file_with_cleaning(
        path.to_string_lossy().to_string(),
        None,
        ContentCleaningOptions {
            convert_mode: "none".into(),
            paragraph_mode: "smart".into(),
            clean_html: true,
            remove_ads: true,
        },
    )
    .unwrap();

    // 2. 阅读中：无规则基线页
    let base = call(&book_id, 0, vec![]);
    let anchor = base.start_char_index;
    assert!(page_text(&base).contains("武圣"));

    // 3. 应用设置：update_book_cleaning（清空分页缓存 + 更新净化器）
    update_book_cleaning(
        book_id.clone(),
        ContentCleaningOptions {
            convert_mode: "none".into(),
            paragraph_mode: "smart".into(),
            clean_html: true,
            remove_ads: true,
        },
    )
    .unwrap();

    // 4. 带锚点重载（与 _loadCurrentPage 一致）：规则必须生效
    let ruled = get_page_processed(
        book_id.clone(),
        0,
        base.page_index,
        360.0,
        640.0,
        18.0,
        1.5,
        20.0,
        20.0,
        20.0,
        20.0,
        "TestFont".to_string(),
        true,
        false,
        0,
        vec![FfiReplaceRule {
            pattern: "武圣".into(),
            replacement: "李明".into(),
            rule_type: 0,
            enabled: true,
        }],
        Some(anchor),
        0.9,
    )
    .expect("reload with rules failed");

    let t_ruled = page_text(&ruled);
    assert!(t_ruled.contains("李明"), "应用设置后规则应立即生效");
    assert!(!t_ruled.contains("武圣"), "原词应被替换");
    // 锚点应停留在包含原位置的页附近
    assert!(ruled.start_char_index <= anchor, "锚点定位不应跳过阅读位置");

    let _ = std::fs::remove_dir_all(&dir);
}
