use ab_glyph::{Font, FontRef, PxScale, ScaleFont};
use anyhow::{anyhow, Result};
use std::collections::HashMap;

/// 内置 Noto Sans CJK SC 字体（7.95 MB，build 时嵌入 binary）
///
/// 跨平台一致的 CJK fallback：Windows / macOS / Linux / Android / iOS 都用
/// 同一字体，Rust 测量与 Dart 绘制同源。
///
/// 源：https://github.com/notofonts/noto-cjk Sans/SubsetOTF/SC
/// 协议：SIL Open Font License 1.1（允许嵌入分发）
const EMBEDDED_NOTO_SANS_SC: &[u8] = include_bytes!("../../../assets/NotoSansSC-Regular.otf");

/// 内置字体注册名（API 层不应假设此名稳定；用 set_default_font 切换）
pub const EMBEDDED_DEFAULT_FONT_NAME: &str = "embedded_default";

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
    /// 默认字体名（启动时由 `new_with_embedded_default` 设置为 EMBEDDED_DEFAULT_FONT_NAME）
    default_font: Option<String>,
}

impl FontManager {
    pub fn new() -> Self {
        Self {
            fonts: HashMap::new(),
            default_font: None,
        }
    }

    /// 构造时自动加载内置 Noto Sans CJK SC 作为默认字体。
    ///
    /// 推荐入口：保证开箱即有 CJK 字体可用，不会因宿主无系统字体而失败。
    /// 如果 init 之后用户用 `load_font` 注入其他字体并 `set_default_font` 切换，
    /// 这个内置字体仍保留在 cache 里作为 fallback。
    pub fn new_with_embedded_default() -> Self {
        let mut mgr = Self::new();
        if let Err(e) = mgr.load_embedded_default() {
            // 内置字体 build 时嵌入，不应失败；若失败 panic 暴露问题
            panic!("加载内置 Noto Sans CJK SC 失败：{}（build 资产缺失？）", e);
        }
        mgr
    }

    /// 加载内置 Noto Sans CJK SC 并设为默认字体
    pub fn load_embedded_default(&mut self) -> Result<()> {
        self.load_font(EMBEDDED_DEFAULT_FONT_NAME.to_string(), EMBEDDED_NOTO_SANS_SC.to_vec())?;
        self.default_font = Some(EMBEDDED_DEFAULT_FONT_NAME.to_string());
        Ok(())
    }

    /// 从字节数组加载字体
    pub fn load_font(&mut self, name: String, data: Vec<u8>) -> Result<()> {
        // 使用 Box::leak 使字体数据生命周期为 'static
        let font_data = Box::leak(data.into_boxed_slice());
        let font = FontRef::try_from_slice(font_data)
            .map_err(|e| anyhow!("加载字体失败: {}", e))?;

        self.fonts.insert(name.clone(), font);

        // 第一个字体设为默认（load_embedded_default 已设默认，内置字体后到的不再覆盖）
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

    /// 获取字体。
    ///
    /// **找不到指定 name 时** fallback 到默认字体（不再抛错）——让上层代码
    /// 在字体配置漂移时仍能继续工作。
    /// fallback 链：`name` → `default_font` → 任意 HashMap entry → 抛错
    pub fn get_font(&self, name: &str) -> Result<&FontRef<'static>> {
        if let Some(f) = self.fonts.get(name) {
            return Ok(f);
        }
        if let Some(default) = self.default_font.as_ref() {
            if let Some(f) = self.fonts.get(default) {
                return Ok(f);
            }
        }
        // 兜底：拿任意一个
        if let Some((_, f)) = self.fonts.iter().next() {
            return Ok(f);
        }
        Err(anyhow!("字体管理器为空：未加载任何字体（应在初始化时 load_embedded_default）"))
    }

    /// 获取默认字体
    pub fn get_default_font(&self) -> Result<&FontRef<'static>> {
        let name = self.default_font.as_ref()
            .ok_or_else(|| anyhow!("未设置默认字体"))?;
        self.get_font(name)
    }

    /// 切换默认字体（用户选字体后调用）。
    ///
    /// 仅在已加载的 fonts 里切换；不会自动加载新文件。
    pub fn set_default_font(&mut self, name: &str) -> Result<()> {
        if !self.fonts.contains_key(name) {
            return Err(anyhow!("未加载此字体：{}（先 load_font）", name));
        }
        self.default_font = Some(name.to_string());
        Ok(())
    }

    /// 获取当前默认字体名
    pub fn default_font_name(&self) -> Option<&str> {
        self.default_font.as_deref()
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
