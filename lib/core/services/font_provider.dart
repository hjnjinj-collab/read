import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'reader_font.dart';

/// 字体来源提供者（用户字体选择 UI 的后端）
///
/// 唯一对外的入口：`pickAndLoadCustomFont()` —— 弹 file_picker，
/// 选 .ttf/.otf 文件，注入到 Rust + Dart 两侧字体管理器。
class FontProvider {
  /// 弹出 file_picker 让用户选字体文件，注入两侧引擎。
  ///
  /// 行为：
  /// 1. file_picker 限定 .ttf/.otf/.ttc
  /// 2. 读 bytes → 推断 name（用文件名 stem + hash 短码）
  /// 3. 调 `ReaderFont.loadCustomFont()` 注入两侧
  /// 4. 失败时回退到默认（不抛错，弹 SnackBar 提示）
  ///
  /// 返回：true=成功切换；false=用户取消或加载失败
  static Future<bool> pickAndLoadCustomFont(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['ttf', 'otf', 'ttc'],
      );
      if (result.isEmpty) return false;

      final picked = result.first;
      // file_picker 12.x：PlatformFile.bytes 字段已移除（之前 deprecated
      // 在 12.x 实现里彻底去掉），只能通过 path 读文件
      if (picked.path == null) {
        if (context.mounted) _toast(context, '选中的文件无路径信息');
        return false;
      }
      final Uint8List bytes = await File(picked.path!).readAsBytes();

      // 字体名：用文件 stem + 短 hash（避免同名冲突 + 不暴露用户路径）
      final rawName = picked.name;
      final stem = rawName.contains('.')
          ? rawName.substring(0, rawName.lastIndexOf('.'))
          : rawName;
      final shortHash = _shortHash(bytes).toRadixString(16);
      final fontName = 'user_${stem}_$shortHash';
      final displayLabel = '用户字体：$stem';

      final ok = await ReaderFont.loadCustomFont(
        name: fontName,
        bytes: bytes,
        displayLabel: displayLabel,
      );
      if (!ok && context.mounted) {
        _toast(context, '字体加载失败：$rawName');
      }
      return ok;
    } catch (e) {
      debugPrint('FontProvider.pickAndLoadCustomFont failed: $e');
      if (context.mounted) {
        _toast(context, '字体选择失败：$e');
      }
      return false;
    }
  }

  /// 32-bit FNV-1a hash（短、稳定）
  static int _shortHash(Uint8List bytes) {
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h ^= b & 0xff;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  /// 简短 toast（不引 SnackBar 库避免额外依赖）
  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}
