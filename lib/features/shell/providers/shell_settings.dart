import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_settings_service.dart';

/// 壳层偏好：书架布局 + 动态取色
@immutable
class ShellSettings {
  const ShellSettings({
    this.bookshelfGrid = true,
    this.dynamicColor = false,
  });

  final bool bookshelfGrid;
  final bool dynamicColor;

  static const String storageKey = 'shell';

  static ShellSettings tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return const ShellSettings();
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return const ShellSettings();
      return ShellSettings(
        bookshelfGrid: map['bookshelfGrid'] as bool? ?? true,
        dynamicColor: map['dynamicColor'] as bool? ?? false,
      );
    } catch (_) {
      return const ShellSettings();
    }
  }

  String encode() => jsonEncode({
        'bookshelfGrid': bookshelfGrid,
        'dynamicColor': dynamicColor,
      });

  ShellSettings copyWith({bool? bookshelfGrid, bool? dynamicColor}) {
    return ShellSettings(
      bookshelfGrid: bookshelfGrid ?? this.bookshelfGrid,
      dynamicColor: dynamicColor ?? this.dynamicColor,
    );
  }
}

class ShellSettingsNotifier extends Notifier<ShellSettings> {
  @override
  ShellSettings build() {
    return ShellSettings.tryParse(AppSettingsService.instance.raw(ShellSettings.storageKey));
  }

  void _persist(ShellSettings next) {
    state = next;
    AppSettingsService.instance.save(ShellSettings.storageKey, next.encode());
  }

  void setBookshelfGrid(bool value) {
    if (state.bookshelfGrid == value) return;
    _persist(state.copyWith(bookshelfGrid: value));
  }

  void setDynamicColor(bool value) {
    if (state.dynamicColor == value) return;
    _persist(state.copyWith(dynamicColor: value));
  }
}

final shellSettingsProvider =
    NotifierProvider<ShellSettingsNotifier, ShellSettings>(ShellSettingsNotifier.new);
