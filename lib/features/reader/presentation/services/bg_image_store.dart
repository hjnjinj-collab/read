import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bg_image_presets.dart';

/// 内置阅读背景图（明/暗成对）缓存与选中状态。
/// 另支持用户自定义壁纸（[customId] + [customPath]）。
class BgImageStore {
  BgImageStore._();

  static final BgImageStore instance = BgImageStore._();

  /// 用户自定义壁纸伪 id
  static const customId = 'custom';

  /// 当前选中预设 id；空 = 纯色纸；[customId] = 用户壁纸
  String selectedId = '';

  /// 自定义壁纸本地路径（空 = 未设置）
  String customPath = '';

  /// 是否暗色（决定用 dark/light 资源；自定义图共用一张）
  bool isDark = false;

  /// 纸色蒙版强度 0–1（绘制热路径同步读）
  static double scrimStrength = 0.35;

  /// 蒙版 alpha：strength × paperOpacity，clamp 0.05–0.85
  static double scrimAlpha(double strength, double paperOpacity) {
    return (strength.clamp(0.0, 1.0) * paperOpacity).clamp(0.05, 0.85);
  }

  final Map<String, ui.Image> _cache = {};
  final Set<String> _loading = {};
  VoidCallback? onImageReady;

  BgImagePreset? get selected {
    for (final p in kBgImagePresets) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  /// 当前应解码的资源键：asset 路径或 `file:<path>`
  String? get currentAsset {
    if (selectedId == customId) {
      return customPath.isEmpty ? null : 'file:$customPath';
    }
    final p = selected;
    if (p == null) return null;
    return p.assetFor(isDark);
  }

  /// 同步取已解码图（绘制热路径）
  ui.Image? get image {
    final asset = currentAsset;
    if (asset == null) return null;
    return _cache[asset];
  }

  void select(String id) {
    if (selectedId == id) return;
    selectedId = id;
    _ensureLoaded();
    onImageReady?.call();
  }

  /// 设置自定义壁纸路径并选中
  void setCustomPath(String path) {
    customPath = path;
    if (path.isNotEmpty) {
      // 路径可能被覆盖写（同名文件）——丢弃旧解码
      _cache.remove('file:$path')?.dispose();
      selectedId = customId;
      _ensureLoaded();
      onImageReady?.call();
    }
  }

  void setDark(bool dark) {
    if (isDark == dark) return;
    isDark = dark;
    _ensureLoaded();
    onImageReady?.call();
  }

  /// 预热当前 + 另一模式 + 前几张缩略
  void warmUp() {
    _ensureLoaded();
    final p = selected;
    if (p != null) {
      _loadAsset(p.assetFor(!isDark));
    }
    for (final q in kBgImagePresets.take(6)) {
      if (q.id == selectedId) continue;
      _loadAsset(q.assetFor(isDark));
    }
  }

  void _ensureLoaded() {
    final asset = currentAsset;
    if (asset != null) _loadAsset(asset);
  }

  Future<void> _loadAsset(String asset) async {
    if (_cache.containsKey(asset) || _loading.contains(asset)) return;
    _loading.add(asset);
    try {
      final img = await _decode(asset);
      if (img != null) {
        _cache[asset] = img;
        if (_cache.length > 8) {
          final first = _cache.keys.first;
          if (first != currentAsset) {
            _cache.remove(first)?.dispose();
          }
        }
        onImageReady?.call();
      }
    } catch (e) {
      debugPrint('BgImageStore load fail $asset: $e');
    } finally {
      _loading.remove(asset);
    }
  }

  Future<ui.Image?> _decode(String key) async {
    if (key.startsWith('file:')) {
      return _decodeFile(key.substring(5));
    }
    return _decodeAsset(key);
  }

  Future<ui.Image?> _decodeFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      debugPrint('BgImageStore decode file fail $path: $e');
      return null;
    }
  }

  Future<ui.Image?> _decodeAsset(String asset) async {
    final ByteData data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void clear() {
    for (final img in _cache.values) {
      img.dispose();
    }
    _cache.clear();
    _loading.clear();
    selectedId = '';
  }
}
