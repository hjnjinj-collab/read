import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader, rootBundle;

import '../ffi/rust_bridge.dart/api.dart' as rust_api;
// M10-B：与 MeasureTextService 形成单向 import（reader_font → measure_text，
// 反向不再 import reader_font），打破循环依赖
import 'measure_text_service.dart';

/// 阅读器字体管理器（M9 字体架构重写）
///
/// **不写死候选路径、不写死具体字体名**——所有字体来源经由：
/// 1. **内置默认字体**：Rust 端 `include_bytes!` 嵌入 Noto Sans CJK SC，
///    跨平台一致，开机即有。FontManager 启动时自动加载为默认。
/// 2. **用户选字体**：`FontProvider.pickAndLoadFromFile()` 经 file_picker
///    选 .ttf/.otf，注入 Rust 端 `loadFontData` + Dart 端 `FontLoader`。
///
/// 双引擎约束（M7）：
/// - Rust 测量必须用与 Dart 绘制**同名字体**
/// - 默认状态下：Rust 用 `embedded_default`（Noto Sans CJK SC），
///   Dart 用 `assets/fonts/NotoSansSC-Regular.otf` 同款
/// - 用户切换时：loadFontData(name, bytes) + FontLoader(name) 同步注册
class ReaderFont {
  /// PagePainter TextStyle.fontFamily 使用此值。
  /// 空串 = 用 Flutter 平台默认（Noto Sans CJK / Microsoft YaHei 等）。
  static String family = '';

  /// 当前活跃字体的人类可读名（用于设置 UI 显示）
  static String displayName = '内置 Noto Sans CJK SC';

  /// 内置字体名（Rust 端 FontManager 注册名）
  static const String embeddedDefaultName = 'embedded_default';

  /// 初始化：把内置字体注册到 Dart 端 FontLoader。
  ///
  /// 必须在 runApp 之前调用。Rust 端的 FontManager 启动时已自动
  /// 加载 `embedded_default`（include_bytes! Noto Sans CJK SC）。
  /// 这里做的是：从 assets 读出**同一文件**注册到 Flutter 的
  /// `ReaderSerif` 字体族，让 PagePainter 用它绘制。
  static Future<void> initialize() async {
    await _registerEmbeddedDefault();
  }

  /// 从 assets 读 NotoSansSC-Regular.otf 注册为 'ReaderSerif'
  static Future<bool> _registerEmbeddedDefault() async {
    try {
      final data = await rootBundle.load('assets/fonts/NotoSansSC-Regular.otf');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final loader = FontLoader('ReaderSerif')
        ..addFont(Future.value(ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes)));
      await loader.load();

      // 探针：检测是否真正生效（若 assets 未打包会回退到默认字体）
      if (!_isFontActive('ReaderSerif')) {
        debugPrint('✗ ReaderSerif (内置 Noto Sans CJK SC) 注册未生效');
        return false;
      }
      family = 'ReaderSerif';
      displayName = '内置 Noto Sans CJK SC';
      debugPrint('✓ ReaderSerif (内置 Noto Sans CJK SC) registered');

      // P4：向 Rust 注册同名字体 + 触发 GB2312 预热——此前启动路径 Rust
      // 侧不知道 'ReaderSerif' 这个热路径字体名，SHARED_GLYPH_CACHE 预热键
      // ("default") 对热路径完全不可见。软失败不阻塞启动（fallback 链兜底）。
      try {
        await rust_api.loadFontData(fontName: family, fontData: bytes);
      } catch (e) {
        debugPrint('✗ Rust 侧 ReaderSerif 注册失败（预热跳过）: $e');
      }
      return true;
    } catch (e) {
      debugPrint('✗ Failed to register ReaderSerif from assets: $e');
      return false;
    }
  }

  /// 加载用户选中的字体（file_picker 选 .ttf/.otf）。
  ///
  /// 同步注册到 Rust + Dart 两侧。返回是否成功。
  /// [name] 字体族名（同时是 FontManager 注册名，也是 FontLoader family）
  /// [bytes] 字体文件原始字节
  /// [displayLabel] 设置 UI 上显示的名字
  static Future<bool> loadCustomFont({
    required String name,
    required Uint8List bytes,
    required String displayLabel,
  }) async {
    try {
      // 1. Rust 端：注入字节，注册到 FontManager
      await rust_api.loadFontData(
        fontName: name,
        fontData: bytes,
      );
      await rust_api.setDefaultFont(fontName: name);

      // 2. Dart 端：注册到 FontLoader，切换 family
      final loader = FontLoader(name)
        ..addFont(Future.value(ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes)));
      await loader.load();

      if (!_isFontActive(name)) {
        debugPrint('✗ $name 注册未生效（advance 与默认一致）');
        return false;
      }

      family = name;
      displayName = displayLabel;
      debugPrint('✓ Custom font loaded: $name ($displayLabel)');

      // M10-B：字体切换后清空 Dart 端测量缓存（key 包含 fontFamily）。
      // 直接 import MeasureTextService；为了避免循环依赖，
      // MeasureTextService 不 import reader_font.dart（见 measure_text_service.dart 顶部说明）。
      // ignore: unawaited_futures
      MeasureTextService.instance.invalidateForFont(name);

      return true;
    } catch (e) {
      debugPrint('✗ Failed to load custom font: $e');
      return false;
    }
  }

  /// 探针：同文本同字号下，指定 family 与 default 比宽度——相同则视为
  /// "未生效"（Flutter 静默回退默认字体不报错）
  static bool _isFontActive(String family) {
    try {
      double measure(String f) {
        final tp = TextPainter(
          text: TextSpan(text: '国国国国', style: TextStyle(fontFamily: f, fontSize: 18)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: double.infinity);
        return tp.width;
      }
      return (measure(family) - measure('')).abs() > 0.5;
    } catch (_) {
      return false;
    }
  }
}
