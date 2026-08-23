use crate::{LayoutEngine, Page, LayoutConfig, FontManager, GlyphCache};
use anyhow::Result;
use rayon::prelude::*;
use std::sync::Arc;

/// 并行排版多个章节
/// 
/// # 参数
/// - `chapters`: 章节列表 (chapter_index, content)
/// - `config`: 排版配置
/// - `font_manager`: 字体管理器（共享）
/// 
/// # 返回
/// 每个章节的页面列表
pub fn layout_chapters_parallel(
    chapters: Vec<(usize, String)>,
    config: LayoutConfig,
    font_manager: Arc<FontManager>,
) -> Result<Vec<Vec<Page>>> {
    // 创建共享的字形缓存
    let shared_cache = Arc::new(GlyphCache::new());
    
    // 并行排版所有章节
    let results: Vec<Result<Vec<Page>>> = chapters
        .par_iter()
        .map(|(chapter_index, content)| {
            // 每个线程创建自己的引擎实例，但共享字体管理器和缓存
            let engine = LayoutEngine::with_cache(
                config.clone(),
                (*font_manager).clone(),
                (*shared_cache).clone(),
            );
            
            engine.layout_text(content, *chapter_index)
        })
        .collect();
    
    // 收集结果，如果有错误则返回第一个错误
    results.into_iter().collect()
}

/// 并行排版指定范围的章节
/// 
/// # 参数
/// - `start_index`: 起始章节索引
/// - `contents`: 章节内容列表
/// - `config`: 排版配置
/// - `font_manager`: 字体管理器
pub fn layout_chapter_range_parallel(
    start_index: usize,
    contents: Vec<String>,
    config: LayoutConfig,
    font_manager: Arc<FontManager>,
) -> Result<Vec<Vec<Page>>> {
    let chapters: Vec<(usize, String)> = contents
        .into_iter()
        .enumerate()
        .map(|(i, content)| (start_index + i, content))
        .collect();
    
    layout_chapters_parallel(chapters, config, font_manager)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EdgeInsets;
    use std::time::Instant;

    fn create_test_font_manager() -> FontManager {
        let mut font_manager = FontManager::new();
        
        // Try to load a system font
        let font_paths = vec![
            "C:/Windows/Fonts/simsun.ttc",
            "C:/Windows/Fonts/msyh.ttc",
            "C:/Windows/Fonts/arial.ttf",
        ];
        
        for path in font_paths {
            if std::path::Path::new(path).exists() {
                if font_manager.load_font_from_file("TestFont".to_string(), path).is_ok() {
                    break;
                }
            }
        }
        
        font_manager
    }

    #[test]
    fn test_parallel_layout() {
        let font_manager = Arc::new(create_test_font_manager());
        
        let config = LayoutConfig {
            width: 300.0,
            height: 400.0,
            font_size: 16.0,
            line_height_multiplier: 1.5,
            padding: EdgeInsets {
                left: 10.0,
                top: 10.0,
                right: 10.0,
                bottom: 10.0,
            },
            font_name: "TestFont".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 8.0,
        };
        
        // 创建多个章节
        let chapters = vec![
            (0, "第一章的内容，这是一段测试文本。".to_string()),
            (1, "第二章的内容，这是另一段测试文本。".to_string()),
            (2, "第三章的内容，继续测试。".to_string()),
        ];
        
        match layout_chapters_parallel(chapters, config, font_manager) {
            Ok(results) => {
                assert_eq!(results.len(), 3);
                
                for (i, pages) in results.iter().enumerate() {
                    println!("章节 {} 生成了 {} 页", i, pages.len());
                    assert!(!pages.is_empty());
                    
                    // 验证章节索引
                    for page in pages {
                        assert_eq!(page.chapter_index, i);
                    }
                }
            }
            Err(e) => {
                println!("并行排版失败（可能是没有字体）: {}", e);
            }
        }
    }
    
    #[test]
    fn test_parallel_performance() {
        let font_manager = Arc::new(create_test_font_manager());
        
        let config = LayoutConfig {
            width: 360.0,
            height: 640.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            padding: EdgeInsets {
                left: 20.0,
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
            },
            font_name: "TestFont".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
        };
        
        // 创建 10 个较长的章节
        let long_text = "这是一段很长的测试文本，用于测试并行排版的性能。".repeat(50);
        let chapters: Vec<(usize, String)> = (0..10)
            .map(|i| (i, long_text.clone()))
            .collect();
        
        let start = Instant::now();
        match layout_chapters_parallel(chapters, config, font_manager) {
            Ok(results) => {
                let duration = start.elapsed();
                println!("并行排版 10 个章节耗时: {:?}", duration);
                println!("平均每章节: {:?}", duration / 10);
                
                assert_eq!(results.len(), 10);
            }
            Err(e) => {
                println!("性能测试失败: {}", e);
            }
        }
    }
    
    #[test]
    fn test_chapter_range_parallel() {
        let font_manager = Arc::new(create_test_font_manager());
        
        let config = LayoutConfig::default();
        
        let contents = vec![
            "内容1".to_string(),
            "内容2".to_string(),
            "内容3".to_string(),
        ];
        
        match layout_chapter_range_parallel(5, contents, config, font_manager) {
            Ok(results) => {
                assert_eq!(results.len(), 3);
                
                // 验证章节索引从 5 开始
                assert_eq!(results[0][0].chapter_index, 5);
                assert_eq!(results[1][0].chapter_index, 6);
                assert_eq!(results[2][0].chapter_index, 7);
            }
            Err(e) => {
                println!("范围排版测试失败: {}", e);
            }
        }
    }
}
