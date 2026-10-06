import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bg_image_presets.dart';

/// 内置阅读背景图（明/暗成对）缓存与选中状态。
class BgImageStore {
  BgImageStore._();

  static final BgImageStore instance = BgImageStore._();

  /// 当前选中预设 id；空 = 纯色纸
  String selectedId = '';

  /// 是否暗色（决定用 dark/light 资源）
  bool isDark = false;

  final Map<String, ui.Image> _cache = {};
  final Set<String> _loading = {};
  VoidCallback? onImageReady;

  BgImagePreset? get selected {
    for (final p in kBgImagePresets) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  String? get currentAsset {
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
      final img = await _decodeAsset(asset);
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
