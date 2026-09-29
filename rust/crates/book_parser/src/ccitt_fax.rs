//! CCITT 传真解码（T.4 Group3 / T.6 Group4）
//!
//! 扫描 PDF 高频 `/Filter /CCITTFaxDecode`：lopdf 不解压，导致原图空白、OCR 无字。
//! 底层使用纯 Rust [`fax`] crate（pdf-rs，专为 PDF CCITTFaxDecode）。
//! 输出 1bpp 行位图（每行按字节对齐，MSB 在前），像素 **1=黑、0=白**。

use anyhow::{bail, Result};
use fax::decoder::{decode_g3, decode_g4, pels};
use fax::Color;

/// CCITT DecodeParms（扫描 PDF 实际用到的子集）
#[derive(Debug, Clone)]
pub struct CcittParams {
    /// K<0 = G4(T.6)；K=0 = G3 纯 1D；K>0 = G3 2D 混合
    pub k: i32,
    /// 每行像素数（宽度）
    pub columns: u32,
    /// 行数；0 表示解到 EOF/EOFB 为止
    pub rows: u32,
    /// true：1 位=黑；false：1 位=白（PDF 默认 false）
    /// 解码后统一输出 1=黑（见模块文档）
    pub black_is1: bool,
    /// 行尾字节对齐
    pub encoded_byte_align: bool,
}

impl Default for CcittParams {
    fn default() -> Self {
        Self {
            k: 0,
            columns: 1728,
            rows: 0,
            black_is1: false,
            encoded_byte_align: false,
        }
    }
}

/// 解码结果：packed 1bpp，每行 ceil(columns/8) 字节
pub struct CcittImage {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
    /// 恒 true：输出约定 1=黑
    pub one_is_black: bool,
}

/// 解码 CCITT 流 → 1bpp 位图（1=黑）
pub fn decode_ccitt(data: &[u8], params: &CcittParams) -> Result<CcittImage> {
    let columns = params.columns.max(1);
    let row_bytes = ((columns as usize) + 7) / 8;
    let want_rows = if params.rows > 0 {
        params.rows as usize
    } else {
        20_000
    };

    let mut rows: Vec<u8> = Vec::with_capacity(row_bytes * want_rows.min(4000));
    let mut height: u32 = 0;

    let mut line_cb = |transitions: &[u32]| {
        if height as usize >= want_rows {
            return;
        }
        let mut row = vec![0u8; row_bytes];
        for (x, color) in pels(transitions, columns).enumerate() {
            if x >= columns as usize {
                break;
            }
            if color == Color::Black {
                let byte = x / 8;
                let bit = 7 - (x % 8);
                if byte < row.len() {
                    row[byte] |= 1 << bit;
                }
            }
        }
        rows.extend_from_slice(&row);
        height += 1;
    };

    let ok = if params.k < 0 {
        decode_g4(
            data.iter().copied(),
            columns,
            Some(want_rows as u32),
            &mut line_cb,
        )
    } else {
        decode_g3(data.iter().copied(), &mut line_cb)
    };

    if ok.is_none() && height == 0 {
        bail!("CCITT 解码失败（K={}）", params.k);
    }
    if height == 0 {
        bail!("CCITT 未解出任何行");
    }

    let black: usize = rows.iter().map(|b| b.count_ones() as usize).sum();
    let total_bits = row_bytes * 8 * height as usize;
    let pct = if total_bits > 0 {
        black as f64 * 100.0 / total_bits as f64
    } else {
        0.0
    };
    eprintln!(
        "ccitt(fax): rows={} black={}/{} ({:.2}%) k={}",
        height, black, total_bits, pct, params.k
    );

    Ok(CcittImage {
        data: rows,
        width: columns,
        height,
        one_is_black: true,
    })
}

/// 诊断：流前 16 字节 hex
pub fn peek_hex(data: &[u8]) -> String {
    data.iter()
        .take(16)
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use fax::encoder::Encoder;
    use fax::VecWriter;

    /// 用 fax 编码器生成 G4 流再解回来（闭环）
    fn roundtrip_g4(line: &[Color], width: u32) -> CcittImage {
        let mut enc = Encoder::new(VecWriter::new());
        enc.encode_line(line.iter().copied(), width).unwrap();
        let w = enc.finish().unwrap();
        let bytes = w.finish();
        let p = CcittParams {
            k: -1,
            columns: width,
            rows: 1,
            black_is1: true,
            encoded_byte_align: false,
        };
        decode_ccitt(&bytes, &p).expect("g4 roundtrip")
    }

    #[test]
    fn g4_roundtrip_black_prefix() {
        let mut line = vec![Color::White; 16];
        for x in 0..8 {
            line[x] = Color::Black;
        }
        let img = roundtrip_g4(&line, 16);
        assert!(img.height >= 1);
        assert_eq!(img.data[0], 0b1111_1111, "前 8 位应为黑");
        assert_eq!(img.data[1], 0b0000_0000, "后 8 位应为白");
    }

    #[test]
    fn g4_roundtrip_all_white() {
        let line = vec![Color::White; 16];
        let img = roundtrip_g4(&line, 16);
        assert!(img.height >= 1);
        assert_eq!(img.data[0], 0);
        assert_eq!(img.data[1], 0);
    }

    #[test]
    fn g4_roundtrip_text_like() {
        let mut enc = Encoder::new(VecWriter::new());
        for row in 0..2u32 {
            let line: Vec<Color> = (0..32)
                .map(|x| {
                    if (x + row * 3) % 7 < 2 {
                        Color::Black
                    } else {
                        Color::White
                    }
                })
                .collect();
            enc.encode_line(line.into_iter(), 32).unwrap();
        }
        let w = enc.finish().unwrap();
        let bytes = w.finish();
        let p = CcittParams {
            k: -1,
            columns: 32,
            rows: 2,
            black_is1: true,
            encoded_byte_align: false,
        };
        let img = decode_ccitt(&bytes, &p).expect("g4 text-like");
        assert_eq!(img.height, 2);
        let black: u32 = img.data.iter().map(|b| b.count_ones()).sum();
        assert!(black > 0, "应有黑像素");
    }

    #[test]
    fn g3_simple() {
        let mut bits: Vec<u8> = Vec::new();
        let mut push = |v: u32, n: u8| {
            for i in (0..n).rev() {
                bits.push(((v >> i) & 1) as u8);
            }
        };
        push(0b000000000001, 12);
        push(0b10011, 5); // 白 8
        push(0b000101, 6); // 黑 8
        push(0b000000000001, 12);
        push(0b000000000001, 12);
        push(0b000000000001, 12);
        push(0b000000000001, 12);
        push(0b000000000001, 12);
        push(0b000000000001, 12);
        let mut bytes = vec![0u8; (bits.len() + 7) / 8];
        for (i, b) in bits.iter().enumerate() {
            if *b == 1 {
                bytes[i / 8] |= 1 << (7 - (i % 8));
            }
        }
        let p = CcittParams {
            k: 0,
            columns: 16,
            rows: 1,
            black_is1: true,
            encoded_byte_align: false,
        };
        let img = decode_ccitt(&bytes, &p).expect("g3");
        assert!(img.height >= 1);
        assert_eq!(img.data[0], 0b0000_0000);
        assert_eq!(img.data[1], 0b1111_1111);
    }
}
