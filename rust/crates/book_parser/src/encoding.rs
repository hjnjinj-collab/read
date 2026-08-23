use anyhow::Result;
use chardetng::EncodingDetector;
use encoding_rs::{Encoding, UTF_8, GBK, BIG5, GB18030};

/// 智能编码检测结果
#[derive(Debug, Clone)]
pub struct EncodingInfo {
    /// 检测到的编码
    pub encoding: &'static Encoding,
    /// 置信度 (0.0 - 1.0)
    pub confidence: f32,
    /// 检测方法
    pub detected_by: &'static str,
}

/// 编码检测器
pub struct SmartEncodingDetector;

impl SmartEncodingDetector {
    /// 智能检测文件编码
    pub fn detect(data: &[u8]) -> Result<EncodingInfo> {
        // Step 1: 检查 BOM
        if let Some(encoding) = Self::detect_bom(data) {
            return Ok(EncodingInfo {
                encoding,
                confidence: 1.0,
                detected_by: "BOM",
            });
        }

        // Step 2: 使用 chardetng 智能检测
        let mut detector = EncodingDetector::new();
        
        // 取前 8KB 进行检测（平衡准确率和性能）
        let sample_size = data.len().min(8192);
        detector.feed(&data[..sample_size], true);
        
        let detected = detector.guess(None, true);
        let confidence = Self::calculate_confidence(detected, &data[..sample_size]);

        // Step 3: 验证检测结果
        if confidence >= 0.9 {
            return Ok(EncodingInfo {
                encoding: detected,
                confidence,
                detected_by: "chardetng",
            });
        }

        // Step 4: 启发式备选方案
        if let Some(encoding_info) = Self::heuristic_detect(data) {
            return Ok(encoding_info);
        }

        // Step 5: 默认 UTF-8
        Ok(EncodingInfo {
            encoding: UTF_8,
            confidence: 0.5,
            detected_by: "default",
        })
    }

    /// 检测 BOM (Byte Order Mark)
    fn detect_bom(data: &[u8]) -> Option<&'static Encoding> {
        if data.len() >= 3 {
            // UTF-8 BOM: EF BB BF
            if &data[0..3] == b"\xEF\xBB\xBF" {
                return Some(UTF_8);
            }
        }
        if data.len() >= 2 {
            // UTF-16 LE: FF FE
            if &data[0..2] == b"\xFF\xFE" {
                return Some(encoding_rs::UTF_16LE);
            }
            // UTF-16 BE: FE FF
            if &data[0..2] == b"\xFE\xFF" {
                return Some(encoding_rs::UTF_16BE);
            }
        }
        None
    }

    /// 计算检测置信度
    fn calculate_confidence(encoding: &'static Encoding, sample: &[u8]) -> f32 {
        let (decoded, _, had_errors) = encoding.decode(sample);
        
        if had_errors {
            return 0.5;
        }

        // 检查常见中文字符占比
        let chinese_chars = decoded.chars()
            .filter(|c| '\u{4E00}' <= *c && *c <= '\u{9FFF}')
            .count();
        
        let total_chars = decoded.chars().count();
        if total_chars == 0 {
            return 0.5;
        }

        let chinese_ratio = chinese_chars as f32 / total_chars as f32;
        
        // 中文书籍通常有 20%-80% 的中文字符
        if chinese_ratio >= 0.2 && chinese_ratio <= 0.8 {
            0.95
        } else if chinese_ratio > 0.0 {
            0.85
        } else {
            0.75
        }
    }

    /// 启发式编码检测
    fn heuristic_detect(data: &[u8]) -> Option<EncodingInfo> {
        // 检测常见中文编码特征
        let candidates = [
            (GBK, "gbk"),
            (GB18030, "gb18030"),
            (BIG5, "big5"),
            (UTF_8, "utf-8"),
        ];
        
        let sample_size = data.len().min(8192);
        let sample = &data[..sample_size];

        let mut best_encoding = None;
        let mut best_score = 0.0f32;

        for (encoding, _name) in &candidates {
            let (decoded, _, had_errors) = encoding.decode(sample);
            
            if had_errors {
                continue;
            }

            // 计算得分
            let score = Self::calculate_text_quality(&decoded);
            
            if score > best_score {
                best_score = score;
                best_encoding = Some(EncodingInfo {
                    encoding: *encoding,
                    confidence: (score / 100.0).min(0.95),
                    detected_by: "heuristic",
                });
            }
        }

        best_encoding
    }

    /// 评估文本质量
    fn calculate_text_quality(text: &str) -> f32 {
        let mut score = 0.0;
        let chars: Vec<char> = text.chars().collect();

        if chars.is_empty() {
            return 0.0;
        }

        // 1. 中文字符占比 (0-40 分)
        let chinese_count = chars.iter()
            .filter(|c| '\u{4E00}' <= **c && **c <= '\u{9FFF}')
            .count();
        score += (chinese_count as f32 / chars.len() as f32) * 40.0;

        // 2. 可打印字符占比 (0-30 分)
        let printable_count = chars.iter()
            .filter(|c| !c.is_control() || c.is_whitespace())
            .count();
        score += (printable_count as f32 / chars.len() as f32) * 30.0;

        // 3. 常见标点符号 (0-20 分)
        let punctuation_chars = ['，', '。', '！', '？', '：', '；', '"', '"', '\'', '\'', '（', '）', '【', '】', '《', '》', '、'];
        let punctuation_count = chars.iter()
            .filter(|c| punctuation_chars.contains(c))
            .count();
        let punctuation_ratio = (punctuation_count as f32 / chars.len() as f32) * 200.0;
        score += punctuation_ratio.min(20.0);

        // 4. 无替换字符 (0-10 分)
        let has_replacement = chars.contains(&'\u{FFFD}');
        if !has_replacement {
            score += 10.0;
        }

        score
    }

    /// 使用检测到的编码解码文本
    pub fn decode_with_info(data: &[u8], encoding_info: &EncodingInfo) -> Result<String> {
        let (decoded, _, _had_errors) = encoding_info.encoding.decode(data);
        
        // 编码信息已记录在 encoding_info 中，可以在需要时访问
        
        Ok(decoded.into_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_utf8_detection() {
        let text = "这是一段UTF-8编码的中文文本。";
        let data = text.as_bytes();
        
        let info = SmartEncodingDetector::detect(data).unwrap();
        
        assert_eq!(info.encoding, UTF_8);
        assert!(info.confidence >= 0.9);
        
        let decoded = SmartEncodingDetector::decode_with_info(data, &info).unwrap();
        assert_eq!(decoded, text);
    }

    #[test]
    fn test_gbk_detection() {
        let text = "这是一段GBK编码的中文文本。";
        let gbk_data = GBK.encode(text).0;
        
        let info = SmartEncodingDetector::detect(&gbk_data).unwrap();
        
        // GBK 或 GB18030 都可以（GB18030 兼容 GBK）
        assert!(info.encoding == GBK || info.encoding == GB18030);
        assert!(info.confidence >= 0.8);
        
        let decoded = SmartEncodingDetector::decode_with_info(&gbk_data, &info).unwrap();
        assert_eq!(decoded, text);
    }

    #[test]
    fn test_bom_detection() {
        let text = "这是一段带BOM的UTF-8文本。";
        let mut data = vec![0xEF, 0xBB, 0xBF];
        data.extend_from_slice(text.as_bytes());
        
        let info = SmartEncodingDetector::detect(&data).unwrap();
        
        assert_eq!(info.encoding, UTF_8);
        assert_eq!(info.confidence, 1.0);
        assert_eq!(info.detected_by, "BOM");
    }

    #[test]
    fn test_no_replacement_chars() {
        let text = "这是一段正常的中文文本，不应该包含替换字符。";
        let data = text.as_bytes();
        
        let info = SmartEncodingDetector::detect(data).unwrap();
        let decoded = SmartEncodingDetector::decode_with_info(data, &info).unwrap();
        
        // 不应包含替换字符
        assert!(!decoded.contains('\u{FFFD}'));
    }

    #[test]
    fn test_text_quality() {
        let good_text = "这是一段高质量的中文文本，包含常见的标点符号。";
        let quality = SmartEncodingDetector::calculate_text_quality(good_text);
        assert!(quality > 60.0);

        let bad_text = "\x00\x01\x02\x03\x04";
        let quality = SmartEncodingDetector::calculate_text_quality(bad_text);
        assert!(quality < 40.0);
    }
}
