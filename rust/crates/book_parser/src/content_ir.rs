//! EPUB 标准化内容 IR v2（路线2：JS 提取 + CSS 物化 + 统一渲染的地基）
//!
//! 契约：JS 提取脚本输出与本模块同构的 JSON（internally tagged，
//! `{"type":"paragraph","text":…}`），经 serde 反序列化得到块树。
//! 顶层为 [`StructuredContent`] 包装：背景等页面级属性不进内容流。
//!
//! 字段分层约定：
//! - `anc` 是 JS 层输出的中间字段（自身+祖先链，供 Rust css_lite 匹配），
//!   CSS 物化完成后必须剥离，不得外泄给渲染层；
//! - 其余新增字段（width_percent/align/intrinsic/hidden/background）
//!   均为物化产物，由 Rust 写入、Flutter 消费。

use serde::{Deserialize, Serialize};

/// 内容 IR 版本号（结构变更时递增；当前消费方按版本兼容判断）
pub const CONTENT_IR_VERSION: u32 = 2;

/// 一章的结构化内容（顶层包装）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StructuredContent {
    pub version: u32,
    /// 页面级背景（body class 的 CSS background-* 物化；None=普通页）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<PageBackground>,
    /// body 的 class 列表（诊断用）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub body_classes: Vec<String>,
    /// 内容块流
    #[serde(default)]
    pub blocks: Vec<ContentBlock>,
}

impl StructuredContent {
    /// 纯文本兜底构造（无背景、无 body 信息）
    pub fn from_fallback_text(text: &str) -> Self {
        Self {
            version: CONTENT_IR_VERSION,
            background: None,
            body_classes: Vec::new(),
            blocks: ContentBlock::fallback_from_text(text),
        }
    }
}

/// 页面级背景（《剑来》装饰页形态：body.qmpN 整页铺图）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PageBackground {
    /// 背景图 ZIP 内路径（Rust 已解析）
    pub image_href: String,
    pub size: BgSize,
    /// CSS background-position 关键字原文（如 "bottom center"/"left top"），
    /// 决定 cover 裁切的锚点方位；None=默认居中
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<String>,
}

/// 背景缩放模式（background-size 物化）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BgSize {
    /// cover / 默认：铺满裁切
    Cover,
    /// contain：完整显示留边
    Contain,
    /// 百分比/像素/两值拉伸：整页拉伸
    Stretch,
}

/// 水平对齐（CSS text-align 物化）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Align {
    Left,
    Center,
    Right,
    /// P2：text-align:justify（此前被折叠为 Left，两端对齐无从谈起）
    Justify,
}

/// 行内富文本段：段落 `text` 的字符区间样式（span/em 等）
///
/// 区间为 `[start, end)` 半开区间，按 Rust char 计数；提取层以私有区
/// 标记锚定边界，空白折叠与去广告改写不影响正确性。空区间在物化时过滤。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StyledRun {
    pub start: usize,
    pub end: usize,
    /// CSS color 物化（#rrggbb 小写规范形；None=继承段落默认色）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// CSS font-size 相对基准字号的倍率（em/% 物化；None=不缩放）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_scale: Option<f32>,
    /// 字形样式：标签语义（b/strong、i/em/cite、a）或 CSS 声明物化
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub bold: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub italic: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub underline: bool,
    /// JS 层中间字段：行内元素自身+祖先链；CSS 匹配后剥离
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anc: Option<Vec<Vec<String>>>,
}

/// 内容块（递归模型：List/Quote/Table 的子结构复用 ContentBlock）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ContentBlock {
    /// 普通段落（可含 `\n` 软换行，来自 `<br>`）
    Paragraph {
        text: String,
        /// CSS 对齐物化（卷首页 p.vol-text 等场景）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        align: Option<Align>,
        /// 块级 color 物化（h2.head1 / td.vol-title-number 等）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
        /// 块级 font-size 相对基准倍率物化（em/%；px 无法脱离页面上下文，忽略）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        font_scale: Option<f32>,
        /// 行内富文本段（span 等样式区段）；空=整段统一
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        runs: Vec<StyledRun>,
        /// JS 层中间字段：自身+祖先链（`[[tag,class..],..]` 根在前、末位为自身）；
        /// CSS 匹配后剥离
        #[serde(default, skip_serializing_if = "Option::is_none")]
        anc: Option<Vec<Vec<String>>>,
        /// 本章说标记：JS 提取层（aside/footnote 等）或 CSS 兜底（小字号段落）
        /// 标记为旁注/注释；布局层据此可缩字、变色或跳过绘制
        #[serde(default)]
        is_comment: bool,
        /// M9：首行缩进（em 倍数，相对基准字号；None=无缩进/继承全局设置）
        /// EPUB 来自 CSS text-indent；TXT 由 ParagraphFormatter 注入
        #[serde(default, skip_serializing_if = "Option::is_none")]
        indent_first_line_em: Option<f32>,
        /// M9：段后间距（em 倍数，叠加在 paragraph_spacing 之上；None=0）
        /// EPUB 来自 CSS margin-bottom
        #[serde(default, skip_serializing_if = "Option::is_none")]
        spacing_after_em: Option<f32>,
        /// P2：行高倍率（EPUB CSS line-height 物化，CSS 继承属性；None=用户全局）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        line_height: Option<f32>,
    },
    /// 标题（h1-h6 → 1..=6）
    Heading {
        level: u8,
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        align: Option<Align>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        font_scale: Option<f32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        anc: Option<Vec<Vec<String>>>,
    },
    /// 图片（resource_href 为 Rust 解析后的 ZIP 内路径）
    Image {
        resource_href: String,
        alt: Option<String>,
        /// CSS width 百分比物化（img.logo{width:100%} → Some(100.0)；
        /// None=默认占满可用宽度）。px 宽度无法脱离页面上下文换算，v1 忽略
        #[serde(default, skip_serializing_if = "Option::is_none")]
        width_percent: Option<f32>,
        /// 自身或最近祖先的 text-align 物化
        #[serde(default, skip_serializing_if = "Option::is_none")]
        align: Option<Align>,
        /// 原始像素尺寸（header 探测；None=失败，布局按默认宽高比）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        intrinsic: Option<(u32, u32)>,
        /// 出血图物化（duokan-bleed 含 left/top：全窗宽绘制、页顶时贴边，
        /// 忽略水平 padding 与 width_percent——《剑来》章头图形态）
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        bleed: bool,
        /// CSS display:none 物化（提取层已过滤，保留字段作防御）
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        hidden: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        anc: Option<Vec<Vec<String>>>,
    },
    /// 列表
    List { ordered: bool, items: Vec<ListItem> },
    /// 引用块
    Quote { blocks: Vec<ContentBlock> },
    /// 分隔线
    Rule,
    /// 表格（列宽提示 + margin 物化；单元格按列排版，
    /// colspan/rowspan 不支持、按文档序对齐）
    Table {
        caption: Option<String>,
        rows: Vec<Vec<TableCell>>,
        /// table 自身+祖先链中间字段（margin/width 类声明匹配用）；物化后剥离
        #[serde(default, skip_serializing_if = "Option::is_none")]
        anc: Option<Vec<Vec<String>>>,
        /// CSS margin-top 百分比物化（table.vol-title{margin:20% 0 0 auto} →
        /// Some(20.0)）：表格前的垂直留白，占可用内容高的百分比
        #[serde(default, skip_serializing_if = "Option::is_none")]
        margin_top_percent: Option<f32>,
        /// CSS margin-left:auto 物化：表格水平右置（块级 auto margin 推挤语义）
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        margin_left_auto: bool,
    },
}

/// 列表项
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListItem {
    pub blocks: Vec<ContentBlock>,
}

/// 表格单元格
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableCell {
    /// th 单元格为 true
    pub header: bool,
    pub blocks: Vec<ContentBlock>,
    /// td/th 自身+祖先链中间字段（td.vol-title-name 等选择器匹配用）；
    /// 物化后剥离
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anc: Option<Vec<Vec<String>>>,
    /// CSS width em 物化（td{width:1.2em} → 列宽提示；None=均分剩余空间）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width_em: Option<f32>,
}

impl ContentBlock {
    /// 构造辅助：纯段落（无样式信息）
    pub fn paragraph(text: impl Into<String>) -> Self {
        ContentBlock::Paragraph {
            text: text.into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: None,
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        }
    }

    /// 构造辅助：标题
    pub fn heading(level: u8, text: impl Into<String>) -> Self {
        ContentBlock::Heading {
            level,
            text: text.into(),
            align: None,
            color: None,
            font_scale: None,
            anc: None,
        }
    }

    /// 构造辅助：图片
    pub fn image(resource_href: impl Into<String>) -> Self {
        ContentBlock::Image {
            resource_href: resource_href.into(),
            alt: None,
            width_percent: None,
            align: None,
            intrinsic: None,
            bleed: false,
            hidden: false,
            anc: None,
        }
    }

    /// 纯文本兜底：每个非空行包成 Paragraph（D9 兜底位的统一出口）
    pub fn fallback_from_text(text: &str) -> Vec<Self> {
        text.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(ContentBlock::paragraph)
            .collect()
    }

    /// 递归解析图片 src 为 ZIP 内路径（按**内容文件所在目录**为基准）
    ///
    /// JS 提取层恒输出 raw src，此处无条件解析（resolve_zip_path
    /// 已正确处理 `./`、`../` 与空目录）。
    pub fn resolve_image_paths(self, content_dir: &str) -> Self {
        match self {
            ContentBlock::Paragraph {
                text,
                align,
                color,
                font_scale,
                runs,
                anc,
                is_comment,
                indent_first_line_em,
                spacing_after_em,
                line_height,
            } => ContentBlock::Paragraph {
                text,
                align,
                color,
                font_scale,
                runs: runs
                    .into_iter()
                    .map(|r| crate::content_ir::StyledRun {
                        start: r.start,
                        end: r.end,
                        color: r.color,
                        font_scale: r.font_scale,
                        bold: r.bold,
                        italic: r.italic,
                        underline: r.underline,
                        anc: r.anc,
                    })
                    .collect(),
                anc,
                is_comment,
                indent_first_line_em,
                spacing_after_em,
                line_height,
            },
            ContentBlock::Heading {
                level,
                text,
                align,
                color,
                font_scale,
                anc,
            } => ContentBlock::Heading {
                level,
                text,
                align,
                color,
                font_scale,
                anc,
            },
            ContentBlock::Image {
                resource_href,
                alt,
                width_percent,
                align,
                intrinsic,
                bleed,
                hidden,
                anc,
            } => ContentBlock::Image {
                resource_href: crate::epub_parser::resolve_zip_path(content_dir, &resource_href),
                alt,
                width_percent,
                align,
                intrinsic,
                bleed,
                hidden,
                anc,
            },
            ContentBlock::Quote { blocks } => ContentBlock::Quote {
                blocks: blocks
                    .into_iter()
                    .map(|b| b.resolve_image_paths(content_dir))
                    .collect(),
            },
            ContentBlock::List { ordered, items } => ContentBlock::List {
                ordered,
                items: items
                    .into_iter()
                    .map(|item| ListItem {
                        blocks: item
                            .blocks
                            .into_iter()
                            .map(|b| b.resolve_image_paths(content_dir))
                            .collect(),
                    })
                    .collect(),
            },
            ContentBlock::Table {
                caption,
                rows,
                anc,
                margin_top_percent,
                margin_left_auto,
            } => ContentBlock::Table {
                caption,
                rows: rows
                    .into_iter()
                    .map(|row| {
                        row.into_iter()
                            .map(|cell| TableCell {
                                header: cell.header,
                                anc: cell.anc,
                                width_em: cell.width_em,
                                blocks: cell
                                    .blocks
                                    .into_iter()
                                    .map(|b| b.resolve_image_paths(content_dir))
                                    .collect(),
                            })
                            .collect()
                    })
                    .collect(),
                anc,
                margin_top_percent,
                margin_left_auto,
            },
            other => other,
        }
    }

    /// 递归剥离 JS 层中间字段 `anc`（CSS 物化完成后的最后一步）
    pub fn strip_anc(self) -> Self {
        match self {
            ContentBlock::Paragraph {
                text,
                align,
                color,
                font_scale,
                runs,
                is_comment,
                indent_first_line_em,
                spacing_after_em,
                line_height,
                ..
            } => ContentBlock::Paragraph {
                text,
                align,
                color,
                font_scale,
                runs: runs
                    .into_iter()
                    .map(|r| crate::content_ir::StyledRun {
                        start: r.start,
                        end: r.end,
                        color: r.color,
                        font_scale: r.font_scale,
                        bold: r.bold,
                        italic: r.italic,
                        underline: r.underline,
                        anc: None,
                    })
                    .collect(),
                anc: None,
                is_comment,
                indent_first_line_em,
                spacing_after_em,
                line_height,
            },
            ContentBlock::Heading {
                level,
                text,
                align,
                color,
                font_scale,
                ..
            } => ContentBlock::Heading {
                level,
                text,
                align,
                color,
                font_scale,
                anc: None,
            },
            ContentBlock::Image {
                resource_href,
                alt,
                width_percent,
                align,
                intrinsic,
                bleed,
                hidden,
                ..
            } => ContentBlock::Image {
                resource_href,
                alt,
                width_percent,
                align,
                intrinsic,
                bleed,
                hidden,
                anc: None,
            },
            ContentBlock::Quote { blocks } => ContentBlock::Quote {
                blocks: blocks.into_iter().map(Self::strip_anc).collect(),
            },
            ContentBlock::List { ordered, items } => ContentBlock::List {
                ordered,
                items: items
                    .into_iter()
                    .map(|item| ListItem {
                        blocks: item.blocks.into_iter().map(Self::strip_anc).collect(),
                    })
                    .collect(),
            },
            ContentBlock::Table {
                caption,
                rows,
                margin_top_percent,
                margin_left_auto,
                ..
            } => ContentBlock::Table {
                caption,
                rows: rows
                    .into_iter()
                    .map(|row| {
                        row.into_iter()
                            .map(|cell| TableCell {
                                header: cell.header,
                                anc: None,
                                width_em: cell.width_em,
                                blocks: cell.blocks.into_iter().map(Self::strip_anc).collect(),
                            })
                            .collect()
                    })
                    .collect(),
                anc: None,
                margin_top_percent,
                margin_left_auto,
            },
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// IR v2 序列化往返：新字段的 serde 默认值与跳过规则
    #[test]
    fn structured_content_roundtrip() {
        let content = StructuredContent {
            version: CONTENT_IR_VERSION,
            background: Some(PageBackground {
                image_href: "OEBPS/Images/back3.jpg".to_string(),
                size: BgSize::Cover,
                position: Some("bottom center".to_string()),
            }),
            body_classes: vec!["qmp2".to_string()],
            blocks: vec![
                ContentBlock::Image {
                    resource_href: "OEBPS/Images/logo.png".to_string(),
                    alt: Some("logo".to_string()),
                    width_percent: Some(100.0),
                    align: Some(Align::Center),
                    intrinsic: Some((600, 200)),
                    bleed: false,
                    hidden: false,
                    anc: None,
                },
                ContentBlock::Paragraph {
                    text: "红字绿字正文".to_string(),
                    align: None,
                    color: Some("#b50a02".to_string()),
                    font_scale: Some(1.4),
                    runs: vec![StyledRun {
                        start: 2,
                        end: 4,
                        color: Some("#498428".to_string()),
                        font_scale: None,
                        bold: false,
                        italic: false,
                        underline: false,
                        anc: Some(vec![vec!["p".into()], vec!["span".into(), "txtu2".into()]]),
                    }],
                    anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
                    is_comment: false,
                    indent_first_line_em: None,
                    spacing_after_em: None,
                    line_height: None,
                },
                ContentBlock::Table {
                    caption: None,
                    rows: vec![vec![crate::content_ir::TableCell {
                        header: false,
                        blocks: vec![ContentBlock::paragraph("卷")],
                        anc: Some(vec![
                            vec!["table".into(), "vol-title".into()],
                            vec!["tr".into()],
                            vec!["td".into(), "vol-title-name".into()],
                        ]),
                        width_em: Some(1.2),
                    }]],
                    anc: Some(vec![vec!["body".into()], vec!["table".into(), "vol-title".into()]]),
                    margin_top_percent: Some(20.0),
                    margin_left_auto: true,
                },
            ],
        };

        let json = serde_json::to_string(&content).unwrap();
        let back: StructuredContent = serde_json::from_str(&json).unwrap();
        assert_eq!(content, back);

        // 剥离后：物化产物保留，中间链路（块级 anc 与 run anc）清空
        let stripped = back.blocks[1].clone().strip_anc();
        let ContentBlock::Paragraph {
            color, font_scale, runs, anc, is_comment, ..
        } = stripped
        else {
            panic!("结构不应改变");
        };
        assert_eq!(color.as_deref(), Some("#b50a02"));
        assert_eq!(font_scale, Some(1.4));
        assert_eq!(runs[0].color.as_deref(), Some("#498428"));
        assert!(runs[0].anc.is_none());
        assert!(anc.is_none());
        assert!(!is_comment);

        let ContentBlock::Table { margin_top_percent, margin_left_auto, anc, rows, .. } =
            back.blocks[2].clone().strip_anc()
        else {
            panic!("结构不应改变");
        };
        assert_eq!(margin_top_percent, Some(20.0));
        assert!(margin_left_auto);
        assert!(anc.is_none());
        assert_eq!(rows[0][0].width_em, Some(1.2));
        assert!(rows[0][0].anc.is_none());

        // 未提供可选字段时 serde 默认值补齐
        let minimal: StructuredContent =
            serde_json::from_str(r#"{"version":2,"blocks":[]}"#).unwrap();
        assert!(minimal.background.is_none());
        assert!(minimal.body_classes.is_empty());

        // 兜底构造
        let fb = StructuredContent::from_fallback_text("第一行\n\n第二行");
        assert_eq!(fb.blocks.len(), 2);
        assert_eq!(fb.version, CONTENT_IR_VERSION);
    }

    /// 字形样式字段：serde 往返 + 旧 JSON（无新字段）向后兼容
    #[test]
    fn styled_run_glyph_fields_roundtrip_and_compat() {
        let run = StyledRun {
            start: 0,
            end: 3,
            color: None,
            font_scale: None,
            bold: true,
            italic: true,
            underline: true,
            anc: None,
        };
        let json = serde_json::to_string(&run).unwrap();
        assert!(json.contains("\"bold\":true"));
        assert!(json.contains("\"italic\":true"));
        assert!(json.contains("\"underline\":true"));
        let back: StyledRun = serde_json::from_str(&json).unwrap();
        assert_eq!(run, back);

        // 无样式 run 序列化零增量（skip_serializing_if）
        let plain = StyledRun {
            start: 0,
            end: 1,
            color: None,
            font_scale: None,
            bold: false,
            italic: false,
            underline: false,
            anc: None,
        };
        let plain_json = serde_json::to_string(&plain).unwrap();
        assert!(!plain_json.contains("bold"));
        assert!(!plain_json.contains("italic"));
        assert!(!plain_json.contains("underline"));

        // M5 之前的 IR JSON（无字形字段）反序列化得 false
        let legacy: StyledRun = serde_json::from_str(
            r##"{"start":0,"end":2,"color":"#ff0000","font_scale":1.5}"##,
        )
        .unwrap();
        assert!(!legacy.bold);
        assert!(!legacy.italic);
        assert!(!legacy.underline);
    }

    /// strip_anc：三层嵌套内全部清除，物化字段保留
    #[test]
    fn strip_anc_recursive() {
        let block = ContentBlock::List {
            ordered: false,
            items: vec![ListItem {
                blocks: vec![ContentBlock::Image {
                    resource_href: "a.png".to_string(),
                    alt: None,
                    width_percent: None,
                    align: Some(Align::Center),
                    intrinsic: None,
                    bleed: false,
                    hidden: false,
                    anc: Some(vec![vec!["body".into()], vec!["div".into(), "logo".into()]]),
                }],
            }],
        };
        let stripped = block.strip_anc();
        let ContentBlock::List { items, .. } = stripped else {
            panic!("结构不应改变");
        };
        let ContentBlock::Image { align, anc, .. } = &items[0].blocks[0] else {
            panic!("结构不应改变");
        };
        assert_eq!(*align, Some(Align::Center));
        assert!(anc.is_none());
    }

    /// resolve_image_paths 保留 v2 新字段
    #[test]
    fn resolve_keeps_v2_fields() {
        let block = ContentBlock::Image {
            resource_href: "../Images/logo.png".to_string(),
            alt: Some("x".to_string()),
            width_percent: Some(60.0),
            align: Some(Align::Right),
            intrinsic: Some((3, 4)),
            bleed: false,
            hidden: false,
            anc: None,
        };
        let resolved = block.resolve_image_paths("OEBPS/Text");
        let ContentBlock::Image {
            resource_href,
            width_percent,
            align,
            intrinsic,
            ..
        } = resolved
        else {
            panic!("结构不应改变");
        };
        assert_eq!(resource_href, "OEBPS/Images/logo.png");
        assert_eq!(width_percent, Some(60.0));
        assert_eq!(align, Some(Align::Right));
        assert_eq!(intrinsic, Some((3, 4)));
    }
}
