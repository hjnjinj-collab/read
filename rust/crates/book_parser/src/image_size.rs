//! 图片原始尺寸探测（手写 header 解析，零新增依赖）
//!
//! 布局引擎分页时就需要图片高度，而 Flutter 侧解码发生在分页之后，
//! 因此尺寸必须由 Rust 侧从字节头获取。只读条目前部字节即可判定：
//! PNG(IHDR) / JPEG(SOFn marker 链) / GIF(逻辑屏幕描述符) / WEBP(VP8|VP8L|VP8X)。
//! 探测失败返回 None，调用方回退默认宽高比。

/// 图片原始像素尺寸
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageDims {
    pub width: u32,
    pub height: u32,
}

impl ImageDims {
    /// 宽高比（w/h）；异常值防御
    pub fn ratio(&self) -> f32 {
        if self.height == 0 {
            return 0.75;
        }
        self.width as f32 / self.height as f32
    }
}

/// 从字节前缀探测图片尺寸；格式不识别或数据截断时返回 None
pub fn probe_image_size(data: &[u8]) -> Option<ImageDims> {
    if data.len() >= 8 && data.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return probe_png(data);
    }
    if data.len() >= 3 && data[0] == 0xFF && data[1] == 0xD8 {
        return probe_jpeg(data);
    }
    if data.len() >= 6 && (&data[..6] == b"GIF87a" || &data[..6] == b"GIF89a") {
        return probe_gif(data);
    }
    if data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        return probe_webp(data);
    }
    None
}

/// PNG：签名(8) + IHDR 长度(4) + "IHDR"(4) + 宽(4 BE) + 高(4 BE)
fn probe_png(data: &[u8]) -> Option<ImageDims> {
    if data.len() < 24 || &data[12..16] != b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes(data[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(data[20..24].try_into().ok()?);
    sane(width, height)
}

/// JPEG：SOI 后扫描 marker 链，SOFn（C0-CF 除 C4/C8/CC）携带高宽
fn probe_jpeg(data: &[u8]) -> Option<ImageDims> {
    let mut pos = 2usize;
    while pos + 4 <= data.len() {
        if data[pos] != 0xFF {
            // marker 填充对齐（连续 0xFF 合法）
            pos += 1;
            continue;
        }
        let marker = data[pos + 1];
        match marker {
            // 独立 marker（无长度域）
            0x01 | 0xD0..=0xD7 => {
                pos += 2;
            }
            // SOS：扫描结束（SOF 必在 SOS 之前）
            0xD9 | 0xDA => return None,
            _ => {
                if pos + 4 > data.len() {
                    return None;
                }
                let seg_len = u16::from_be_bytes(data[pos + 2..pos + 4].try_into().ok()?) as usize;
                if seg_len < 2 {
                    return None;
                }
                let is_sof = (0xC0..=0xCF).contains(&marker) && ![0xC4, 0xC8, 0xCC].contains(&marker);
                if is_sof {
                    // SOF 段内：精度(1) + 高(2 BE) + 宽(2 BE)
                    let base = pos + 4;
                    if base + 5 > data.len() {
                        return None;
                    }
                    let height = u16::from_be_bytes(data[base + 1..base + 3].try_into().ok()?) as u32;
                    let width = u16::from_be_bytes(data[base + 3..base + 5].try_into().ok()?) as u32;
                    return sane(width, height);
                }
                pos += 2 + seg_len;
            }
        }
    }
    None
}

/// GIF：逻辑屏幕描述符位于头部 6 字节后（宽高各 2 字节小端）
fn probe_gif(data: &[u8]) -> Option<ImageDims> {
    if data.len() < 10 {
        return None;
    }
    let width = u16::from_le_bytes(data[6..8].try_into().ok()?) as u32;
    let height = u16::from_le_bytes(data[8..10].try_into().ok()?) as u32;
    sane(width, height)
}

/// WEBP：按 chunk 类型分派
fn probe_webp(data: &[u8]) -> Option<ImageDims> {
    let chunk = &data[12..16];
    match chunk {
        b"VP8 " => probe_vp8_lossy(data),
        b"VP8L" => probe_vp8_lossless(data),
        b"VP8X" => probe_vp8_extended(data),
        _ => None,
    }
}

/// VP8 有损：帧头 3 字节 + 同步码 9D 01 2A + 宽高各 2 字节（低 14 位有效）
fn probe_vp8_lossy(data: &[u8]) -> Option<ImageDims> {
    // chunk header(12..20) + frame tag(20..23) + sync(23..26)，尺寸自 26 起
    let base = 26;
    if data.len() < base + 4 || data[base - 3..base] != [0x9D, 0x01, 0x2A] {
        return None;
    }
    let w = u16::from_le_bytes(data[base..base + 2].try_into().ok()?) & 0x3FFF;
    let h = u16::from_le_bytes(data[base + 2..base + 4].try_into().ok()?) & 0x3FFF;
    sane(w as u32 + 1, h as u32 + 1)
}

/// VP8L 无损：chunk data 首字节 0x2F 签名，随后 14+14 位打包宽高
fn probe_vp8_lossless(data: &[u8]) -> Option<ImageDims> {
    // chunk header(12..20) + 签名(20)，位流自 21 起
    if data.len() < 25 || data[20] != 0x2F {
        return None;
    }
    let b0 = data[21] as u32;
    let b1 = data[22] as u32;
    let b2 = data[23] as u32;
    let b3 = data[24] as u32;
    let width = 1 + (((b1 & 0x3F) << 8) | b0);
    let height = 1 + (((b1 >> 6) & 0x03) | (b2 << 2) | ((b3 & 0x0F) << 10));
    sane(width, height)
}

/// VP8X 扩展：flags(4) 后画布宽高各 3 字节小端（值-1）
fn probe_vp8_extended(data: &[u8]) -> Option<ImageDims> {
    let base = 24; // chunk header(8) + 保留/flags(4)
    if data.len() < base + 6 {
        return None;
    }
    let width = u32::from(data[base] as u32)
        | (u32::from(data[base + 1]) << 8)
        | (u32::from(data[base + 2]) << 16);
    let height = u32::from(data[base + 3] as u32)
        | (u32::from(data[base + 4]) << 8)
        | (u32::from(data[base + 5]) << 16);
    sane(width + 1, height + 1)
}

/// 零尺寸视为探测失败
fn sane(width: u32, height: u32) -> Option<ImageDims> {
    if width == 0 || height == 0 {
        None
    } else {
        Some(ImageDims { width, height })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_ihdr() {
        let mut data = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        data.extend_from_slice(&[0, 0, 0, 0x0D]);
        data.extend_from_slice(b"IHDR");
        data.extend_from_slice(&1920u32.to_be_bytes());
        data.extend_from_slice(&1080u32.to_be_bytes());
        data.extend_from_slice(&[8, 6, 0, 0, 0]);

        assert_eq!(
            probe_image_size(&data),
            Some(ImageDims {
                width: 1920,
                height: 1080
            })
        );
        // 截断数据：探测失败而非 panic
        assert_eq!(probe_image_size(&data[..20]), None);
    }

    #[test]
    fn jpeg_sof0_after_app0() {
        // SOI + APP0(JFIF) + SOF0：高 3 宽 4
        let mut data = vec![0xFF, 0xD8];
        data.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0]);
        data.extend_from_slice(&[0; 11]);
        data.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]);
        data.extend_from_slice(&3u16.to_be_bytes()); // height
        data.extend_from_slice(&4u16.to_be_bytes()); // width
        data.extend_from_slice(&[1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);

        assert_eq!(
            probe_image_size(&data),
            Some(ImageDims {
                width: 4,
                height: 3
            })
        );
    }

    #[test]
    fn gif_logical_screen() {
        let mut data = b"GIF89a".to_vec();
        data.extend_from_slice(&320u16.to_le_bytes());
        data.extend_from_slice(&200u16.to_le_bytes());
        data.extend_from_slice(&[0xF0, 0, 0]);

        assert_eq!(
            probe_image_size(&data),
            Some(ImageDims {
                width: 320,
                height: 200
            })
        );
    }

    #[test]
    fn webp_extended_chunk() {
        let mut data = b"RIFF\x24\x00\x00\x00WEBP".to_vec();
        data.extend_from_slice(b"VP8X");
        data.extend_from_slice(&10u32.to_le_bytes());
        data.extend_from_slice(&[0x10, 0, 0, 0]); // flags（4 字节）
        data.extend_from_slice(&[199, 0, 0]); // width-1 = 200 (LE24)
        data.extend_from_slice(&[149, 0, 0]); // height-1 = 150 (LE24)

        assert_eq!(
            probe_image_size(&data),
            Some(ImageDims {
                width: 200,
                height: 150
            })
        );
    }

    #[test]
    fn webp_lossless_chunk() {
        let mut data = b"RIFF\x14\x00\x00\x00WEBP".to_vec();
        data.extend_from_slice(b"VP8L");
        data.extend_from_slice(&6u32.to_le_bytes());
        data.push(0x2F); // 签名
        // 取足够大的高使第 4 字节非零，验证掩码正确性
        let w_minus_1 = 1199u32;
        let h_minus_1 = 1999u32;
        let bits = w_minus_1 | (h_minus_1 << 14);
        data.push((bits & 0xFF) as u8);
        data.push(((bits >> 8) & 0xFF) as u8);
        data.push(((bits >> 16) & 0xFF) as u8);
        data.push(((bits >> 24) & 0xFF) as u8);

        assert_eq!(
            probe_image_size(&data),
            Some(ImageDims {
                width: 1200,
                height: 2000
            })
        );
    }

    #[test]
    fn webp_lossy_chunk() {
        let mut data = b"RIFF\x1A\x00\x00\x00WEBP".to_vec();
        data.extend_from_slice(b"VP8 ");
        data.extend_from_slice(&16u32.to_le_bytes());
        data.extend_from_slice(&[0x30, 0x01, 0x00]); // frame tag（值不参与解析）
        data.extend_from_slice(&[0x9D, 0x01, 0x2A]); // 同步码
        data.extend_from_slice(&((800u16 - 1)).to_le_bytes());
        data.extend_from_slice(&((600u16 - 1)).to_le_bytes());

        assert_eq!(
            probe_image_size(&data),
            Some(ImageDims {
                width: 800,
                height: 600
            })
        );
    }

    #[test]
    fn unknown_and_empty_input() {
        assert_eq!(probe_image_size(b""), None);
        assert_eq!(probe_image_size(b"not an image"), None);
        // BMP 不在支持列表
        assert_eq!(probe_image_size(b"BM\x36\x00"), None);
    }

    #[test]
    fn ratio_defends_zero_height() {
        assert!((ImageDims { width: 4, height: 3 }.ratio() - 4.0 / 3.0).abs() < 1e-6);
        assert!((ImageDims { width: 4, height: 0 }.ratio() - 0.75).abs() < 1e-6);
    }
}
