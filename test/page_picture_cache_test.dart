import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/models/simple_models.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_picture_cache.dart';

void main() {
  const size = Size(200, 400);

  const key = PageRenderKey(
    fontSize: 18,
    lineHeight: 1.5,
    applyBold: false,
    applyItalic: false,
    applyTitleBold: false,
    width: 200,
    height: 400,
  );

  PageInfo page(int index, {String? backgroundHref}) => PageInfo(
        pageIndex: index,
        startCharIndex: 0,
        endCharIndex: 10,
        backgroundHref: backgroundHref,
        entries: const [
          PageEntry(text: '测试文本行', x: 10, y: 20, width: 180, height: 24),
        ],
      );

  ui.Picture record(PageInfo p) => recordPagePicture(
        p,
        size,
        applyBold: false,
        applyItalic: false,
        applyTitleBold: false,
        baseFontSize: 18,
        baseLineHeight: 1.5,
      ).picture;

  group('PagePictureCache', () {
    test('put 后 get 返回同一 Picture 实例', () {
      final cache = PagePictureCache();
      final p = page(0);
      final pic = record(p);
      cache.put(p, key, pic);
      expect(identical(cache.get(p, key), pic), isTrue);
      cache.clear();
    });

    test('排版参数指纹不符视为 miss 并丢弃旧纹理', () {
      final cache = PagePictureCache();
      final p = page(0);
      cache.put(p, key, record(p));
      final otherKey = const PageRenderKey(
        fontSize: 20,
        lineHeight: 1.5,
        applyBold: false,
        applyItalic: false,
        applyTitleBold: false,
        width: 200,
        height: 400,
      );
      expect(cache.get(p, otherKey), isNull);
      // 丢弃后可重新 put（旧纹理已 dispose，不重复占用）
      cache.put(p, otherKey, record(p));
      expect(cache.get(p, otherKey), isNotNull);
      cache.clear();
    });

    test('LRU 淘汰：超出容量时最旧条目失效', () {
      final cache = PagePictureCache(capacity: 2);
      final p0 = page(0);
      final p1 = page(1);
      final p2 = page(2);
      cache.put(p0, key, record(p0));
      cache.put(p1, key, record(p1));
      // 触碰 p0 使 p1 成为最旧
      cache.get(p0, key);
      cache.put(p2, key, record(p2));
      expect(cache.get(p1, key), isNull);
      expect(cache.get(p0, key), isNotNull);
      expect(cache.get(p2, key), isNotNull);
      cache.clear();
    });

    test('invalidate 后 miss；clear 清空全部', () {
      final cache = PagePictureCache();
      final p0 = page(0);
      final p1 = page(1);
      cache.put(p0, key, record(p0));
      cache.put(p1, key, record(p1));
      cache.invalidate(p0);
      expect(cache.get(p0, key), isNull);
      expect(cache.get(p1, key), isNotNull);
      cache.clear();
      expect(cache.get(p1, key), isNull);
    });

    test('同页重复 put 替换旧条目且不超容量', () {
      final cache = PagePictureCache(capacity: 2);
      final p0 = page(0);
      cache.put(p0, key, record(p0));
      cache.put(p0, key, record(p0));
      expect(cache.get(p0, key), isNotNull);
      cache.clear();
    });
  });

  group('recordPagePicture', () {
    test('同步录制产出 Picture；未就绪图片 href 进入 pendingImages', () {
      final p = page(3, backgroundHref: 'OEBPS/bg.png');
      final r = recordPagePicture(
        p,
        size,
        applyBold: false,
        applyItalic: false,
        applyTitleBold: false,
        baseFontSize: 18,
        baseLineHeight: 1.5,
      );
      expect(r.picture, isA<ui.Picture>());
      expect(r.pendingImages, contains('OEBPS/bg.png'));
      r.picture.dispose();
    });

    test('录制含图片项的页面：resourceHref 计入 pending 且去重', () {
      const p = PageInfo(
        pageIndex: 4,
        startCharIndex: 0,
        endCharIndex: 10,
        entries: [
          PageEntry(resourceHref: 'OEBPS/img.png', x: 0, y: 0, width: 50, height: 50),
          PageEntry(resourceHref: 'OEBPS/img.png', x: 60, y: 0, width: 50, height: 50),
          PageEntry(text: '文字行', x: 0, y: 100, width: 180, height: 24),
        ],
      );
      final r = recordPagePicture(
        p,
        size,
        applyBold: false,
        applyItalic: false,
        applyTitleBold: false,
        baseFontSize: 18,
        baseLineHeight: 1.5,
      );
      expect(r.pendingImages, ['OEBPS/img.png']);
      r.picture.dispose();
    });
  });
}
