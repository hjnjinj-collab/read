use ab_glyph::{Font, FontRef, PxScale, ScaleFont};
use anyhow::{anyhow, Result};
use std::collections::HashMap;

/// 字形度量数据
#[derive(Debug, Clone, Copy)]
pub struct GlyphMetrics {
    pub width: f32,
    pub height: f32,
    pub baseline_offset: f32,
}

/// 字体管理器
#[derive(Clone)]
pub struct FontManager {
    /// 字体缓存：字体名 -> 字体数据
    fonts: HashMap<String, FontRef<'static>>,
    /// 默认字体名
    default_font: Option<String>,
}

impl FontManager {
    pub fn new() -> Self {
        Self {
            fonts: HashMap::new(),
            default_font: None,
        }
    }
    
    /// 从字节数组加载字体
    pub fn load_font(&mut self, name: String, data: Vec<u8>) -> Result<()> {
        // 使用 Box::leak 使字体数据生命周期为 'static
        let font_data = Box::leak(data.into_boxed_slice());
        let font = FontRef::try_from_slice(font_data)
            .map_err(|e| anyhow!("加载字体失败: {}", e))?;
        
        self.fonts.insert(name.clone(), font);
        
        // 第一个字体设为默认
        if self.default_font.is_none() {
            self.default_font = Some(name);
        }
        
        Ok(())
    }
    
    /// 从文件加载字体
    pub fn load_font_from_file(&mut self, name: String, path: &str) -> Result<()> {
        let data = std::fs::read(path)
            .map_err(|e| anyhow!("读取字体文件失败: {}", e))?;
        self.load_font(name, data)
    }
    
    /// 获取字体
    pub fn get_font(&self, name: &str) -> Result<&FontRef<'static>> {
        self.fonts.get(name)
            .ok_or_else(|| anyhow!("字体不存在: {}", name))
    }
    
    /// 获取默认字体
    pub fn get_default_font(&self) -> Result<&FontRef<'static>> {
        let name = self.default_font.as_ref()
            .ok_or_else(|| anyhow!("未设置默认字体"))?;
        self.get_font(name)
    }
    
    /// 测量单个字符的宽度
    pub fn measure_char(&self, font: &FontRef, ch: char, font_size: f32) -> GlyphMetrics {
        let scale = PxScale::from(font_size);
        let scaled_font = font.as_scaled(scale);
        
        let glyph_id = font.glyph_id(ch);
        let h_advance = scaled_font.h_advance(glyph_id);
        let v_metrics = scaled_font.height();
        
        GlyphMetrics {
            width: h_advance,
            height: v_metrics,
            baseline_offset: scaled_font.descent(),
        }
    }
    
    /// 获取已加载的字体数量
    pub fn font_count(&self) -> usize {
        self.fonts.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_font_manager_creation() {
        let manager = FontManager::new();
        assert_eq!(manager.font_count(), 0);
    }
    
    #[test]
    #[ignore] // 需要实际字体文件，CI 环境可能没有
    fn test_load_font_from_file() {
        let mut manager = FontManager::new();
        
        // Windows 系统字体路径
        let font_paths = vec![
            "C:/Windows/Fonts/simsun.ttc",
            "C:/Windows/Fonts/msyh.ttc",
            "C:/Windows/Fonts/arial.ttf",
        ];
        
        for path in font_paths {
            if std::path::Path::new(path).exists() {
                let result = manager.load_font_from_file(
                    "TestFont".to_string(),
                    path
                );
                
                if result.is_ok() {
                    assert_eq!(manager.font_count(), 1);
                    
                    // 测试字形测量
                    let font = manager.get_default_font().unwrap();
                    let metrics = manager.measure_char(font, '中', 16.0);
                    
                    assert!(metrics.width > 0.0);
                    println!("字符 '中' 宽度: {}", metrics.width);
                    break;
                }
            }
        }
    }
}
