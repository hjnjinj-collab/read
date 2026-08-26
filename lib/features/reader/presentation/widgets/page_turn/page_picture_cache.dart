import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../../core/models/simple_models.dart';
import '../../services/book_image_store.dart';
import '../reader_page_widget.dart';

/// 排版参数指纹：任一参数/尺寸变化即视为不同缓存键
@immutable
class PageRenderKey {
  final double fontSize;
  final double lineHeight;
  final bool applyBold;
  final bool applyItalic;
  final bool applyTitleBold;
  final double width;
  final double height;

  const PageRenderKey({
    required this.fontSize,
    required this.lineHeight,
    required this.applyBold,
    required this.applyItalic,
    required this.applyTitleBold,
    required this.width,
    required this.height,
  });

  @override
  bool operator ==(Object other) =>
      other is PageRenderKey &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.applyBold == applyBold &&
      other.applyItalic == applyItalic &&
      other.applyTitleBold == applyTitleBold &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(fontSize, lineHeight, applyBold, applyItalic,
      applyTitleBold, width, height);
}

/// 页面纹理缓存（翻页动画专用）
///
/// 以 [recordPagePicture] 同步录制整页绘制结果（纸色底 + 内容渲染器），
/// 拖拽开始时同步取用——无异步快照窗口、首帧即正确内容（对齐 legado
/// 常备 curBitmap/nextBitmap 的做法）。按 PageInfo 身份 + [PageRenderKey]
/// 做键，LRU 淘汰即 dispose；图片异步解码完成后由持有方调 [invalidate]
/// 触发重录。缓存独占所有 Picture 的生命周期（持有方只借用引用）。
class PagePictureCache {
  PagePictureCache({this.capacity = 6});

  final int capacity;

  // Dart 字面量 Map 即 LinkedHashMap（插入序）：remove+重插实现 LRU 触碰
  final Map<PageInfo, _Entry> _entries = {};

  /// 取纹理；键不符（排版参数/尺寸已变）视为 miss 并丢弃旧纹理
  ui.Picture? get(PageInfo page, PageRenderKey key) {
    final entry = _entries.remove(page);
    if (entry == null) return null;
    if (entry.renderKey != key) {
      entry.picture.dispose();
      return null;
    }
    _entries[page] = entry;
    return entry.picture;
  }

  void put(PageInfo page, PageRenderKey key, ui.Picture picture) {
    final old = _entries.remove(page);
    old?.picture.dispose();
    _entries[page] = _Entry(picture: picture, renderKey: key);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first)?.picture.dispose();
    }
  }

  /// 使缓存项失效（dispose 旧纹理）。调用方须保证该纹理未正被画布
  /// 引用，或在同一同步块内完成引用替换 + 重绘调度。
  void invalidate(PageInfo page) {
    _entries.remove(page)?.picture.dispose();
  }

  void clear() {
    for (final entry in _entries.values) {
      entry.picture.dispose();
    }
    _entries.clear();
  }
}

class _Entry {
  final ui.Picture picture;
  final PageRenderKey renderKey;

  const _Entry({required this.picture, required this.renderKey});
}

/// 同步录制整页纹理（纸色底 + 背景图 + entries）
///
/// 逻辑坐标绘制（随画布变换重放），无 toImage 的像素比损耗；
/// 返回值携带「尚未就绪的图片 href」，由调用方注册解码回调。
({ui.Picture picture, List<String> pendingImages}) recordPagePicture(
  PageInfo page,
  Size size, {
  required bool applyBold,
  required bool applyItalic,
  required bool applyTitleBold,
  required double baseFontSize,
  required double baseLineHeight,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Offset.zero & size,
    Paint()..color = const Color(0xFFF5F1E8),
  );
  PageContentRenderer.paintPage(
    canvas,
    page,
    size: size,
    onImageNeeded: () {},
    applyBold: applyBold,
    applyItalic: applyItalic,
    applyTitleBold: applyTitleBold,
    baseFontSize: baseFontSize,
    baseLineHeight: baseLineHeight,
  );
  final picture = recorder.endRecording();

  final pending = <String>[];
  void checkHref(String? href) {
    if (href == null || pending.contains(href)) return;
    if (BookImageStore.instance.get(href) == null) pending.add(href);
  }

  checkHref(page.backgroundHref);
  for (final entry in page.entries) {
    checkHref(entry.resourceHref);
  }
  return (picture: picture, pendingImages: pending);
}
