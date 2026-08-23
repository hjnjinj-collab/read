use anyhow::Result;
#[cfg(feature = "js-engine")]
use anyhow::Context;
use serde::{Deserialize, Serialize};
#[cfg(feature = "js-engine")]
use std::time::Duration;
#[cfg(feature = "js-engine")]
use tokio::time::timeout;

/// 章节信息（从 JS 返回，仅包含标题位置）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsChapterInfo {
    pub title: String,
    #[serde(rename = "lineNumber")]
    pub line_number: usize,
}

/// 完整的章节信息（包含内容边界和层级）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterInfo {
    /// 章节标题
    pub title: String,
    /// 章节内容起始字节位置
    pub start_offset: usize,
    /// 章节内容结束字节位置
    pub end_offset: usize,
    /// 章节层级 (0=卷, 1=章, 2=节)
    pub level: u8,
    /// 父章节索引（用于嵌套结构，None 表示顶层）
    pub parent_index: Option<usize>,
    /// 章节序号（在同级中的顺序）
    pub index: usize,
}

/// 章节验证结果
#[derive(Debug, Clone)]
pub struct ChapterValidation {
    pub is_valid: bool,
    pub reason: Option<String>,
    pub content_length: usize,
}

/// 章节识别规则
#[derive(Debug, Clone)]
pub struct ChapterRule {
    pub name: String,
    pub priority: u8,
    pub script: String,
}

/// 章节提取器（基于 JS 引擎）
pub struct ChapterExtractor {
    default_rules: Vec<ChapterRule>,
    timeout_secs: u64,
    /// 最小章节长度（字节）
    min_chapter_length: usize,
    /// 最大章节长度（字节）
    max_chapter_length: usize,
}

impl ChapterExtractor {
    /// 创建新的章节提取器
    pub fn new() -> Self {
        Self {
            default_rules: Self::build_default_rules(),
            timeout_secs: 5,
            min_chapter_length: 500,      // 最小 500 字节
            max_chapter_length: 100_000,  // 最大 100KB
        }
    }

    /// 使用 JS 引擎提取章节
    ///
    /// 注意：这个方法是同步的，因为我们使用 spawn_blocking 调用
    #[cfg(feature = "js-engine")]
    pub async fn extract_with_js(
        &self,
        content: &str,
        rule_script: &str,
    ) -> Result<Vec<JsChapterInfo>> {
        let content = content.to_string();
        let script = rule_script.to_string();
        let timeout_duration = Duration::from_secs(self.timeout_secs);

        // 使用 spawn_blocking 在阻塞线程中执行 JS
        let result = timeout(timeout_duration, tokio::task::spawn_blocking(move || {
            Self::execute_js_sync(&content, &script)
        }))
        .await
        .context("JS 执行超时")?
        .context("JS 执行任务失败")?;

        result
    }

    /// 同步执行 JS（在 spawn_blocking 中调用）
    #[cfg(feature = "js-engine")]
    fn execute_js_sync(content: &str, script: &str) -> Result<Vec<JsChapterInfo>> {
        use rquickjs::{Context, Runtime};

        let runtime = Runtime::new().context("创建 JS Runtime 失败")?;
        let context = Context::full(&runtime).context("创建 JS Context 失败")?;

        context.with(|ctx| {
            // 注入内容到全局变量
            ctx.globals()
                .set("content", content)
                .context("设置 content 变量失败")?;

            // 执行脚本
            let result: rquickjs::Value = ctx
                .eval(script)
                .context("执行 JS 脚本失败")?;

            // 解析返回值
            let json_str: String = ctx
                .json_stringify(result)
                .context("序列化 JS 返回值失败")?
                .ok_or_else(|| anyhow::anyhow!("JS 返回值为 undefined"))?
                .get()
                .context("获取 JSON 字符串失败")?;

            let chapters: Vec<JsChapterInfo> =
                serde_json::from_str(&json_str).context("解析章节列表失败")?;

            Ok(chapters)
        })
    }

    /// 使用默认规则提取章节（仅返回标题位置）
    #[cfg(feature = "js-engine")]
    pub async fn extract_with_default(&self, content: &str) -> Result<Vec<JsChapterInfo>> {
        // 按优先级尝试每个规则
        for rule in &self.default_rules {
            match self.extract_with_js(content, &rule.script).await {
                Ok(chapters) if !chapters.is_empty() => {
                    log::info!("使用规则 '{}' 成功提取 {} 个章节", rule.name, chapters.len());
                    return Ok(chapters);
                }
                Ok(_) => {
                    log::debug!("规则 '{}' 未找到章节", rule.name);
                }
                Err(e) => {
                    log::warn!("规则 '{}' 执行失败: {}", rule.name, e);
                }
            }
        }

        Err(anyhow::anyhow!("所有默认规则都未能识别章节"))
    }

    /// 将 JsChapterInfo 转换为完整的 ChapterInfo（包含内容边界和层级）
    pub fn build_chapter_info(
        &self,
        content: &str,
        js_chapters: Vec<JsChapterInfo>,
    ) -> Result<Vec<ChapterInfo>> {
        if js_chapters.is_empty() {
            return Ok(vec![]);
        }

        // 用原始字节扫描行起始偏移，兼容 \n 与 \r\n。
        // 注意：content.lines() 会剥掉 \r，用 lines()[i].len()+1 累加会在
        // CRLF 文件上每行少算 1 字节，导致章节边界累积漂移。
        let mut line_starts: Vec<usize> = Vec::new();
        line_starts.push(0);
        for (i, b) in content.bytes().enumerate() {
            if b == b'\n' {
                line_starts.push(i + 1);
            }
        }
        let line_start = |line_number: usize| -> usize {
            if line_number < line_starts.len() {
                line_starts[line_number]
            } else {
                content.len()
            }
        };

        let mut chapters: Vec<ChapterInfo> = Vec::new();

        for (idx, js_chapter) in js_chapters.iter().enumerate() {
            // 章节内容的起始位置：标题行的下一行行首（不含标题）
            let start_offset = line_start(js_chapter.line_number + 1);

            // 章节内容的结束位置：下一个章节标题行的行首
            let end_offset = if idx + 1 < js_chapters.len() {
                line_start(js_chapters[idx + 1].line_number)
            } else {
                // 最后一章，到文件结尾
                content.len()
            };

            // 确保字节边界合法
            let start_offset = if content.is_char_boundary(start_offset) {
                start_offset
            } else {
                // 向后找到最近的字符边界
                (start_offset..content.len())
                    .find(|&i| content.is_char_boundary(i))
                    .unwrap_or(content.len())
            };

            let mut end_offset = if content.is_char_boundary(end_offset) {
                end_offset
            } else {
                // 向前找到最近的字符边界
                (0..=end_offset)
                    .rev()
                    .find(|&i| content.is_char_boundary(i))
                    .unwrap_or(0)
            };

            // 确保 start_offset <= end_offset
            if start_offset > end_offset {
                // 如果调整后出现倒序，使用原始 start 向后找 end
                end_offset = (start_offset..content.len())
                    .find(|&i| content.is_char_boundary(i))
                    .unwrap_or(content.len());
            }
            
            // 如果仍然无效（极端情况），跳过这个章节
            if start_offset >= end_offset {
                continue;
            }

            // 识别章节层级
            let level = Self::detect_chapter_level(&js_chapter.title);

            // 查找父章节（向前查找最近的上一级章节）
            let parent_index = if level > 0 {
                chapters
                    .iter()
                    .enumerate()
                    .rev()
                    .find(|(_, ch)| ch.level < level)
                    .map(|(i, _)| i)
            } else {
                None
            };

            chapters.push(ChapterInfo {
                title: js_chapter.title.clone(),
                start_offset,
                end_offset,
                level,
                parent_index,
                index: idx,
            });
        }

        Ok(chapters)
    }

    /// 检测章节层级
    fn detect_chapter_level(title: &str) -> u8 {
        // 卷 > 部 > 篇 (level 0)
        if title.contains("卷") || title.contains("部") || title.contains("篇") {
            return 0;
        }
        // 章 (level 1)
        if title.contains("章") || title.starts_with("Chapter") {
            return 1;
        }
        // 节 (level 2)
        if title.contains("节") || title.contains("Section") {
            return 2;
        }
        // 默认为章级别
        1
    }

    /// 验证章节内容的合理性
    pub fn validate_chapter(&self, content: &str, chapter: &ChapterInfo) -> ChapterValidation {
        // 防御性检查：确保偏移量有效
        if chapter.start_offset >= chapter.end_offset || chapter.end_offset > content.len() {
            return ChapterValidation {
                is_valid: false,
                reason: Some(format!(
                    "章节偏移量无效 (start={}, end={}, content_len={})",
                    chapter.start_offset, chapter.end_offset, content.len()
                )),
                content_length: 0,
            };
        }

        let chapter_content = &content[chapter.start_offset..chapter.end_offset];
        let content_length = chapter_content.len();

        // 检查长度
        if content_length < self.min_chapter_length {
            return ChapterValidation {
                is_valid: false,
                reason: Some(format!(
                    "章节内容过短 ({} 字节 < {} 字节最小要求)",
                    content_length, self.min_chapter_length
                )),
                content_length,
            };
        }

        if content_length > self.max_chapter_length {
            return ChapterValidation {
                is_valid: false,
                reason: Some(format!(
                    "章节内容过长 ({} 字节 > {} 字节最大限制)",
                    content_length, self.max_chapter_length
                )),
                content_length,
            };
        }

        // 检查内容有效性（不只是空白）
        let non_whitespace_chars: usize = chapter_content.chars().filter(|c| !c.is_whitespace()).count();
        if non_whitespace_chars < 100 {
            return ChapterValidation {
                is_valid: false,
                reason: Some(format!(
                    "章节内容几乎为空（仅 {} 个非空白字符）",
                    non_whitespace_chars
                )),
                content_length,
            };
        }

        ChapterValidation {
            is_valid: true,
            reason: None,
            content_length,
        }
    }

    /// 提取并验证完整章节信息（一站式接口）
    #[cfg(feature = "js-engine")]
    pub async fn extract_chapters(&self, content: &str) -> Result<Vec<ChapterInfo>> {
        // 1. 使用 JS 引擎识别章节标题
        let js_chapters = self.extract_with_default(content).await?;

        // 2. 构建完整章节信息（内容边界 + 层级）
        let chapters = self.build_chapter_info(content, js_chapters)?;
        let total_count = chapters.len();

        // 3. 验证并过滤
        let valid_chapters: Vec<ChapterInfo> = chapters
            .into_iter()
            .filter(|ch| {
                let validation = self.validate_chapter(content, ch);
                if !validation.is_valid {
                    log::warn!(
                        "章节 '{}' 验证失败: {}",
                        ch.title,
                        validation.reason.unwrap_or_default()
                    );
                    false
                } else {
                    log::debug!(
                        "章节 '{}' 验证通过 ({} 字节)",
                        ch.title,
                        validation.content_length
                    );
                    true
                }
            })
            .collect();

        if valid_chapters.is_empty() {
            return Err(anyhow::anyhow!("所有章节都未通过验证"));
        }

        log::info!(
            "成功提取 {} 个有效章节（过滤前 {} 个）",
            valid_chapters.len(),
            total_count
        );

        Ok(valid_chapters)
    }

    /// 构建内置默认规则
    fn build_default_rules() -> Vec<ChapterRule> {
        vec![
            // 优先级最高：卷章结构（同时支持卷和章，支持阿拉伯数字和中文数字）
            ChapterRule {
                name: "卷章结构".to_string(),
                priority: 100,
                script: r#"
(function() {
    let chapters = [];
    let lines = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        // 支持: 第1章、第一章、第1卷、第一卷
        if (/^第[\d零一二三四五六七八九十百千]+[卷章]/.test(line)) {
            chapters.push({title: line, lineNumber: i});
        }
    }
    return chapters;
})();
"#.to_string(),
            },
            // 标准网文格式（仅章，支持阿拉伯数字和中文数字）
            ChapterRule {
                name: "标准网文格式".to_string(),
                priority: 90,
                script: r#"
(function() {
    let chapters = [];
    let lines = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        // 支持: 第1章、第一章
        if (/^第[\d零一二三四五六七八九十百千]+章/.test(line)) {
            chapters.push({title: line, lineNumber: i});
        }
    }
    return chapters;
})();
"#.to_string(),
            },
            ChapterRule {
                name: "英文书籍格式".to_string(),
                priority: 80,
                script: r#"
(function() {
    let chapters = [];
    let lines = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        if (/^Chapter\s+\d+/i.test(line)) {
            chapters.push({title: line, lineNumber: i});
        }
    }
    return chapters;
})();
"#.to_string(),
            },
            ChapterRule {
                name: "数字编号格式".to_string(),
                priority: 70,
                script: r#"
(function() {
    let chapters = [];
    let lines = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        if (line.length >= 3 && line.length <= 30 && /^\d{1,4}[\.、\s]/.test(line)) {
            chapters.push({title: line, lineNumber: i});
        }
    }
    return chapters;
})();
"#.to_string(),
            },
            ChapterRule {
                name: "特殊章节".to_string(),
                priority: 60,
                script: r#"
(function() {
    let chapters = [];
    let lines = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        if (/^(序章|楔子|序言|引子|尾声|后记|番外|终章)/.test(line)) {
            chapters.push({title: line, lineNumber: i});
        }
    }
    return chapters;
})();
"#.to_string(),
            },
        ]
    }
}

impl Default for ChapterExtractor {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(all(test, feature = "js-engine"))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_extract_standard_format() {
        let content = r#"
这是一些前言内容

第一章 开始的故事
这是第一章的内容。

第二章 继续冒险
这是第二章的内容。

第三章 最终章
这是最后的内容。
"#;

        let extractor = ChapterExtractor::new();
        let chapters = extractor.extract_with_default(content).await.unwrap();

        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0].title, "第一章 开始的故事");
        assert_eq!(chapters[1].title, "第二章 继续冒险");
        assert_eq!(chapters[2].title, "第三章 最终章");
    }

    #[tokio::test]
    async fn test_extract_english_format() {
        let content = r#"
Prologue

Chapter 1
First chapter content.

Chapter 2
Second chapter content.
"#;

        let extractor = ChapterExtractor::new();
        let chapters = extractor.extract_with_default(content).await.unwrap();

        assert!(chapters.len() >= 2);
        assert!(chapters[0].title.contains("Chapter"));
    }

    #[tokio::test]
    async fn test_build_chapter_info_with_content() {
        let content = r#"前言内容
第一章 开始
这是第一章的内容，需要足够长才能通过验证。
我们需要添加更多的文字来确保章节内容超过500字节的最小限制。
让我们继续添加一些内容：春眠不觉晓，处处闻啼鸟。
夜来风雨声，花落知多少。床前明月光，疑是地上霜。
举头望明月，低头思故乡。白日依山尽，黄河入海流。
欲穷千里目，更上一层楼。锄禾日当午，汗滴禾下土。
谁知盘中餐，粒粒皆辛苦。鹅鹅鹅，曲项向天歌。
白毛浮绿水，红掌拨清波。离离原上草，一岁一枯荣。
野火烧不尽，春风吹又生。慈母手中线，游子身上衣。
临行密密缝，意恐迟迟归。谁言寸草心，报得三春晖。

第二章 继续
这是第二章的内容，同样需要足够长才能通过验证。
我们添加更多文字：独在异乡为异客，每逢佳节倍思亲。
遥知兄弟登高处，遍插茱萸少一人。渭城朝雨浥轻尘，
客舍青青柳色新。劝君更尽一杯酒，西出阳关无故人。
千山鸟飞绝，万径人踪灭。孤舟蓑笠翁，独钓寒江雪。
两个黄鹂鸣翠柳，一行白鹭上青天。窗含西岭千秋雪，
门泊东吴万里船。日照香炉生紫烟，遥看瀑布挂前川。
飞流直下三千尺，疑是银河落九天。朝辞白帝彩云间，
千里江陵一日还。两岸猿声啼不住，轻舟已过万重山。

第三章 结局
这是最后一章的内容，也需要足够长。
继续添加：春种一粒粟，秋收万颗子。四海无闲田，
农夫犹饿死。谁道人生无再少，门前流水尚能西。
休将白发唱黄鸡。采菊东篱下，悠然见南山。
山气日夕佳，飞鸟相与还。此中有真意，欲辨已忘言。
大江东去，浪淘尽，千古风流人物。故垒西边，人道是，
三国周郎赤壁。乱石穿空，惊涛拍岸，卷起千堆雪。
江山如画，一时多少豪杰。遥想公瑾当年，小乔初嫁了，
雄姿英发。羽扇纶巾，谈笑间，樯橹灰飞烟灭。
故国神游，多情应笑我，早生华发。人生如梦，一尊还酹江月。
"#;

        let extractor = ChapterExtractor::new();
        let js_chapters = extractor.extract_with_default(content).await.unwrap();
        let chapters = extractor.build_chapter_info(content, js_chapters).unwrap();

        assert_eq!(chapters.len(), 3);
        
        // 验证第一章
        assert_eq!(chapters[0].title, "第一章 开始");
        assert_eq!(chapters[0].level, 1); // 章级别
        assert_eq!(chapters[0].parent_index, None);
        let ch1_content = &content[chapters[0].start_offset..chapters[0].end_offset];
        assert!(ch1_content.contains("这是第一章的内容"));
        
        // 验证第二章
        assert_eq!(chapters[1].title, "第二章 继续");
        assert_eq!(chapters[1].level, 1);
        let ch2_content = &content[chapters[1].start_offset..chapters[1].end_offset];
        assert!(ch2_content.contains("这是第二章的内容"));
        
        // 验证第三章
        assert_eq!(chapters[2].title, "第三章 结局");
        assert_eq!(chapters[2].level, 1);
        let ch3_content = &content[chapters[2].start_offset..chapters[2].end_offset];
        assert!(ch3_content.contains("这是最后一章的内容"));
    }

    #[tokio::test]
    async fn test_nested_structure() {
        let content = r#"序言
第一卷 天道无情
这是卷的介绍文字，需要足够长才能通过验证。
添加更多内容：春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。
床前明月光，疑是地上霜。举头望明月，低头思故乡。白日依山尽，黄河入海流。
欲穷千里目，更上一层楼。锄禾日当午，汗滴禾下土。谁知盘中餐，粒粒皆辛苦。
鹅鹅鹅，曲项向天歌。白毛浮绿水，红掌拨清波。离离原上草，一岁一枯荣。
野火烧不尽，春风吹又生。慈母手中线，游子身上衣。临行密密缝，意恐迟迟归。
谁言寸草心，报得三春晖。独在异乡为异客，每逢佳节倍思亲。

第一章 初入江湖
这是第一章的内容，属于第一卷。需要足够长的内容。
继续添加文字：遥知兄弟登高处，遍插茱萸少一人。渭城朝雨浥轻尘，
客舍青青柳色新。劝君更尽一杯酒，西出阳关无故人。千山鸟飞绝，万径人踪灭。
孤舟蓑笠翁，独钓寒江雪。两个黄鹂鸣翠柳，一行白鹭上青天。
窗含西岭千秋雪，门泊东吴万里船。日照香炉生紫烟，遥看瀑布挂前川。
飞流直下三千尺，疑是银河落九天。朝辞白帝彩云间，千里江陵一日还。
两岸猿声啼不住，轻舟已过万重山。春种一粒粟，秋收万颗子。

第二章 武林风云
这是第二章的内容，也属于第一卷。需要更多文字。
四海无闲田，农夫犹饿死。谁道人生无再少，门前流水尚能西。休将白发唱黄鸡。
采菊东篱下，悠然见南山。山气日夕佳，飞鸟相与还。此中有真意，欲辨已忘言。
大江东去，浪淘尽，千古风流人物。故垒西边，人道是，三国周郎赤壁。
乱石穿空，惊涛拍岸，卷起千堆雪。江山如画，一时多少豪杰。
遥想公瑾当年，小乔初嫁了，雄姿英发。羽扇纶巾，谈笑间，樯橹灰飞烟灭。
故国神游，多情应笑我，早生华发。人生如梦，一尊还酹江月。

第二卷 剑道独尊
这是第二卷的介绍。添加更多诗词内容。
明月几时有，把酒问青天。不知天上宫阙，今夕是何年。
我欲乘风归去，又恐琼楼玉宇，高处不胜寒。起舞弄清影，何似在人间。
转朱阁，低绮户，照无眠。不应有恨，何事长向别时圆。
人有悲欢离合，月有阴晴圆缺，此事古难全。但愿人长久，千里共婵娟。
滚滚长江东逝水，浪花淘尽英雄。是非成败转头空，青山依旧在，几度夕阳红。

第三章 剑意初成
这是第三章，属于第二卷。更多内容填充。
白发渔樵江渚上，惯看秋月春风。一壶浊酒喜相逢，古今多少事，都付笑谈中。
怒发冲冠，凭栏处，潇潇雨歇。抬望眼，仰天长啸，壮怀激烈。
三十功名尘与土，八千里路云和月。莫等闲，白了少年头，空悲切。
靖康耻，犹未雪。臣子恨，何时灭。驾长车，踏破贺兰山缺。
壮志饥餐胡虏肉，笑谈渴饮匈奴血。待从头，收拾旧山河，朝天阙。
"#;

        let extractor = ChapterExtractor::new();
        let js_chapters = extractor.extract_with_default(content).await.unwrap();
        
        // 调试输出
        println!("识别到 {} 个章节标题：", js_chapters.len());
        for (i, ch) in js_chapters.iter().enumerate() {
            println!("  [{}] {} (行号: {})", i, ch.title, ch.line_number);
        }
        
        let chapters = extractor.build_chapter_info(content, js_chapters).unwrap();

        // 应该识别出 5 个章节（2 卷 + 3 章）
        assert_eq!(chapters.len(), 5, "应该识别出 5 个章节（2卷+3章），实际: {}", chapters.len());
        
        // 第一卷（level 0，无父节点）
        assert_eq!(chapters[0].title, "第一卷 天道无情");
        assert_eq!(chapters[0].level, 0);
        assert_eq!(chapters[0].parent_index, None);
        
        // 第一章（level 1，父节点是第一卷）
        assert_eq!(chapters[1].title, "第一章 初入江湖");
        assert_eq!(chapters[1].level, 1);
        assert_eq!(chapters[1].parent_index, Some(0));
        
        // 第二章（level 1，父节点是第一卷）
        assert_eq!(chapters[2].title, "第二章 武林风云");
        assert_eq!(chapters[2].level, 1);
        assert_eq!(chapters[2].parent_index, Some(0));
        
        // 第二卷（level 0，无父节点）
        assert_eq!(chapters[3].title, "第二卷 剑道独尊");
        assert_eq!(chapters[3].level, 0);
        assert_eq!(chapters[3].parent_index, None);
        
        // 第三章（level 1，父节点是第二卷）
        assert_eq!(chapters[4].title, "第三章 剑意初成");
        assert_eq!(chapters[4].level, 1);
        assert_eq!(chapters[4].parent_index, Some(3));
    }

    #[tokio::test]
    async fn test_chapter_validation() {
        // 测试内容过短的章节
        let short_content = r#"
第一章 太短
这章内容太短了。

第二章 正常
这是正常长度的章节内容。需要足够长才能通过验证。
春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。
床前明月光，疑是地上霜。举头望明月，低头思故乡。
白日依山尽，黄河入海流。欲穷千里目，更上一层楼。
锄禾日当午，汗滴禾下土。谁知盘中餐，粒粒皆辛苦。
鹅鹅鹅，曲项向天歌。白毛浮绿水，红掌拨清波。
离离原上草，一岁一枯荣。野火烧不尽，春风吹又生。
慈母手中线，游子身上衣。临行密密缝，意恐迟迟归。
谁言寸草心，报得三春晖。独在异乡为异客，每逢佳节倍思亲。
遥知兄弟登高处，遍插茱萸少一人。渭城朝雨浥轻尘，客舍青青柳色新。
"#;

        let extractor = ChapterExtractor::new();
        let chapters = extractor.extract_chapters(short_content).await.unwrap();
        
        // 第一章应该被过滤掉，只剩第二章
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "第二章 正常");
    }

    #[tokio::test]
    async fn test_arabic_number_chapters() {
        let content = r#"《贷款武圣》
作者：长鲸归海

第1章 捕役之身
这是第一章的内容，需要足够长才能通过验证。
添加更多内容：春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。
床前明月光，疑是地上霜。举头望明月，低头思故乡。白日依山尽，黄河入海流。
欲穷千里目，更上一层楼。锄禾日当午，汗滴禾下土。谁知盘中餐，粒粒皆辛苦。
鹅鹅鹅，曲项向天歌。白毛浮绿水，红掌拨清波。离离原上草，一岁一枯荣。
野火烧不尽，春风吹又生。慈母手中线，游子身上衣。临行密密缝，意恐迟迟归。
谁言寸草心，报得三春晖。独在异乡为异客，每逢佳节倍思亲。

第2章 武学初窥
这是第二章的内容，也需要足够长。
继续添加文字：遥知兄弟登高处，遍插茱萸少一人。渭城朝雨浥轻尘，
客舍青青柳色新。劝君更尽一杯酒，西出阳关无故人。千山鸟飞绝，万径人踪灭。
孤舟蓑笠翁，独钓寒江雪。两个黄鹂鸣翠柳，一行白鹭上青天。
窗含西岭千秋雪，门泊东吴万里船。日照香炉生紫烟，遥看瀑布挂前川。
飞流直下三千尺，疑是银河落九天。朝辞白帝彩云间，千里江陵一日还。
两岸猿声啼不住，轻舟已过万重山。春种一粒粟，秋收万颗子。

第3章 修炼之路
这是第三章的内容，继续添加。
四海无闲田，农夫犹饿死。谁道人生无再少，门前流水尚能西。休将白发唱黄鸡。
采菊东篱下，悠然见南山。山气日夕佳，飞鸟相与还。此中有真意，欲辨已忘言。
大江东去，浪淘尽，千古风流人物。故垒西边，人道是，三国周郎赤壁。
乱石穿空，惊涛拍岸，卷起千堆雪。江山如画，一时多少豪杰。
遥想公瑾当年，小乔初嫁了，雄姿英发。羽扇纶巾，谈笑间，樯橹灰飞烟灭。
故国神游，多情应笑我，早生华发。人生如梦，一尊还酹江月。

第100章 百章大关
这是第一百章，测试三位数数字识别。
明月几时有，把酒问青天。不知天上宫阙，今夕是何年。
我欲乘风归去，又恐琼楼玉宇，高处不胜寒。起舞弄清影，何似在人间。
转朱阁，低绮户，照无眠。不应有恨，何事长向别时圆。
人有悲欢离合，月有阴晴圆缺，此事古难全。但愿人长久，千里共婵娟。
滚滚长江东逝水，浪花淘尽英雄。是非成败转头空，青山依旧在，几度夕阳红。
白发渔樵江渚上，惯看秋月春风。一壶浊酒喜相逢，古今多少事，都付笑谈中。
"#;

        let extractor = ChapterExtractor::new();
        let chapters = extractor.extract_chapters(content).await.unwrap();

        // 应该识别出 4 个章节
        assert_eq!(chapters.len(), 4, "应该识别出 4 个章节，实际: {}", chapters.len());
        
        assert_eq!(chapters[0].title, "第1章 捕役之身");
        assert_eq!(chapters[1].title, "第2章 武学初窥");
        assert_eq!(chapters[2].title, "第3章 修炼之路");
        assert_eq!(chapters[3].title, "第100章 百章大关");
        
        // 验证所有章节都是 level 1（章）
        for chapter in &chapters {
            assert_eq!(chapter.level, 1);
        }
    }

    #[tokio::test]
    #[ignore] // 需要大文件，手动运行
    async fn test_large_file_with_1000_chapters() {
        use std::fs;
        
        let file_path = "D:\\android\\example\\legado_flutter\\rust\\test_large_file_cargo\\test_very_large_book.txt";
        
        // 检查文件是否存在
        if !std::path::Path::new(file_path).exists() {
            println!("跳过测试：大文件不存在 {}", file_path);
            return;
        }
        
        let content = fs::read_to_string(file_path).expect("读取文件失败");
        
        println!("文件大小: {} KB", content.len() / 1024);
        
        let extractor = ChapterExtractor::new();
        let start = std::time::Instant::now();
        let chapters = extractor.extract_chapters(&content).await.expect("提取章节失败");
        let elapsed = start.elapsed();
        
        println!("识别到 {} 个章节", chapters.len());
        println!("耗时: {:?}", elapsed);
        
        // 显示前10章和后10章
        println!("\n前10章:");
        for (i, ch) in chapters.iter().take(10).enumerate() {
            println!("  [{}] {} (Level {}, 内容: {} 字节)", 
                i, ch.title, ch.level, ch.end_offset - ch.start_offset);
        }
        
        if chapters.len() > 10 {
            println!("\n后10章:");
            for (i, ch) in chapters.iter().skip(chapters.len().saturating_sub(10)).enumerate() {
                let idx = chapters.len() - 10 + i;
                println!("  [{}] {} (Level {}, 内容: {} 字节)", 
                    idx, ch.title, ch.level, ch.end_offset - ch.start_offset);
            }
        }
        
        // 验证：应该接近1000章（允许一些被过滤）
        assert!(chapters.len() >= 900, "应该识别出至少900章，实际: {}", chapters.len());
        assert!(chapters.len() <= 1000, "不应该超过1000章，实际: {}", chapters.len());
    }
}
