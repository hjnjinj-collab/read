// 编码诊断工具模块

use anyhow::Result;
use std::fs::File;
use std::io::Read;

/// 编码诊断结果
#[derive(Debug, Clone)]
pub struct EncodingDiagnostic {
    /// 检测到的编码
    pub detected_encoding: String,
    /// 文件字节长度
    pub byte_length: usize,
    /// 解码后字符长度
    pub char_length: usize,
    /// 前100个字符样本
    pub sample_text: String,
    /// 是否有解码错误
    pub has_errors: bool,
    /// UTF-8 验证结果
    pub is_valid_utf8: bool,
}

/// 诊断文件编码
pub fn diagnose_file_encoding(file_path: &str) -> Result<EncodingDiagnostic> {
    let mut file = File::open(file_path)?;
    let mut buffer = Vec::new();
    file.read_to_end(&mut buffer)?;
    
    diagnose_buffer_encoding(&buffer)
}

/// 诊断字节缓冲区编码
pub fn diagnose_buffer_encoding(buffer: &[u8]) -> Result<EncodingDiagnostic> {
    let byte_length = buffer.len();
    
    // 1. 检查是否是有效的 UTF-8
    let is_valid_utf8 = std::str::from_utf8(buffer).is_ok();
    
    // 2. 尝试不同编码解码
    let (detected_encoding, decoded_string, has_errors) = detect_and_decode(buffer);
    
    // 3. 获取字符长度和样本
    let char_length = decoded_string.chars().count();
    let sample_text: String = decoded_string.chars().take(100).collect();
    
    Ok(EncodingDiagnostic {
        detected_encoding,
        byte_length,
        char_length,
        sample_text,
        has_errors,
        is_valid_utf8,
    })
}

/// 检测并解码
fn detect_and_decode(buffer: &[u8]) -> (String, String, bool) {
    // 1. 检测 UTF-8 BOM
    if buffer.len() >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF {
        if let Ok(s) = std::str::from_utf8(&buffer[3..]) {
            return ("UTF-8-BOM".to_string(), s.to_string(), false);
        }
    }
    
    // 2. 尝试 UTF-8
    if let Ok(s) = std::str::from_utf8(buffer) {
        return ("UTF-8".to_string(), s.to_string(), false);
    }
    
    // 3. 尝试 GB18030
    if let Some(encoding) = encoding_rs::Encoding::for_label(b"gb18030") {
        let (decoded, _, had_errors) = encoding.decode(buffer);
        if !had_errors {
            return ("GB18030".to_string(), decoded.to_string(), false);
        }
    }
    
    // 4. 尝试 GBK
    if let Some(encoding) = encoding_rs::Encoding::for_label(b"gbk") {
        let (decoded, _, had_errors) = encoding.decode(buffer);
        if !had_errors {
            return ("GBK".to_string(), decoded.to_string(), false);
        }
    }
    
    // 5. 尝试 Big5
    if let Some(encoding) = encoding_rs::Encoding::for_label(b"big5") {
        let (decoded, _, had_errors) = encoding.decode(buffer);
        if !had_errors {
            return ("Big5".to_string(), decoded.to_string(), false);
        }
    }
    
    // 6. 兜底：UTF-8 lossy
    let decoded = String::from_utf8_lossy(buffer).to_string();
    ("UTF-8-lossy".to_string(), decoded, true)
}

/// 诊断章节内容
pub fn diagnose_chapter_content(
    content: &str,
) -> Result<String> {
    let char_count = content.chars().count();
    let byte_count = content.len();
    let line_count = content.lines().count();
    
    // 检测特殊字符
    let replacement_char_count = content.chars().filter(|&c| c == '�').count();
    let control_char_count = content.chars().filter(|c| c.is_control() && *c != '\n' && *c != '\r' && *c != '\t').count();
    
    // 获取前10行样本
    let sample_lines: Vec<&str> = content.lines().take(10).collect();
    let sample = sample_lines.join("\n");
    
    Ok(format!(
        "字符数: {}\n字节数: {}\n行数: {}\n替换字符(�): {}\n控制字符: {}\n\n前10行样本:\n{}",
        char_count, byte_count, line_count, replacement_char_count, control_char_count, sample
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_diagnose_utf8() {
        let text = "这是UTF-8测试文本";
        let buffer = text.as_bytes();
        let result = diagnose_buffer_encoding(buffer).unwrap();
        
        assert_eq!(result.detected_encoding, "UTF-8");
        assert!(result.is_valid_utf8);
        assert!(!result.has_errors);
    }
    
    #[test]
    fn test_diagnose_utf8_bom() {
        let mut buffer = vec![0xEF, 0xBB, 0xBF]; // UTF-8 BOM
        buffer.extend_from_slice("测试文本".as_bytes());
        
        let result = diagnose_buffer_encoding(&buffer).unwrap();
        assert_eq!(result.detected_encoding, "UTF-8-BOM");
        assert!(!result.has_errors);
    }
    
    #[test]
    fn test_diagnose_chapter_content() {
        let content = "第一章 测试\n\n这是内容。\n包含多行。";
        let result = diagnose_chapter_content(content).unwrap();
        
        assert!(result.contains("字符数:"));
        assert!(result.contains("行数:"));
    }
}
