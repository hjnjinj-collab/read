import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;

/// 阅读器绘制字体（M7 字体统一）
///
/// Rust 断行测量用 ab_glyph 加载系统字体文件测 advance；Dart 绘制必须
/// 注册**同一字体文件**，否则双引擎 advance 不同源 → TextPainter 二次
/// 换行 → 行内容重叠/截断。注册失败时静默回退平台默认（保底可读）。
class ReaderFont {
  /// PagePainter 全部 TextStyle 使用此 family
  static String family = 'sans-serif';

  /// 候选表与 main.dart 的 Rust 侧加载顺序一致——取首个成功路径同时
  /// 喂给两侧引擎
  static const List<String> candidatePaths = [
    'C:/Windows/Fonts/simsun.ttc',
    'C:/Windows/Fonts/msyh.ttc',
    'C:/Windows/Fonts/simhei.ttf',
    'C:/Windows/Fonts/simkai.ttf',
    'C:/Windows/Fonts/arial.ttf',
  ];

  /// 把 [path] 的字体字节注册为 'ReaderSerif' 并探测是否真正生效。
  ///
  /// ⚠ family 未注册成功时 Flutter 会**静默回退**默认字体不报错，
  /// 故用「同文本量宽对比缺省」作探针：宽度相同即视为失败。
  static Future<bool> registerFromFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final loader = FontLoader('ReaderSerif')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();

      double measure(String family) {
        final tp = TextPainter(
          text: TextSpan(
            text: '国国国国',
            style: TextStyle(fontFamily: family, fontSize: 18),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: double.infinity);
        return tp.width;
      }

      if (measure('ReaderSerif') == measure('sans-serif')) {
        debugPrint('✗ ReaderSerif 注册未生效（宽度与默认一致）: $path');
        return false;
      }
      family = 'ReaderSerif';
      debugPrint('✓ ReaderSerif registered from $path');
      return true;
    } catch (e) {
      debugPrint('✗ Failed to register ReaderSerif from $path: $e');
      return false;
    }
  }
}
