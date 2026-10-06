import 'package:flutter/services.dart';

/// 音量键翻页（Android `legado/keys` 通道）。
/// 仅阅读页且设置开启时拦截音量键；关闭时原生放行系统音量。
class VolumePageKeys {
  VolumePageKeys._();

  static const _channel = MethodChannel('legado/keys');
  static bool _hooked = false;

  /// 音量上=上一页、下=下一页（与系统阅读器习惯一致）
  static void Function()? onPrev;
  static void Function()? onNext;

  static void _ensureHooked() {
    if (_hooked) return;
    _hooked = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'volumeUp':
          onPrev?.call();
        case 'volumeDown':
          onNext?.call();
      }
      return null;
    });
  }

  /// 开/关拦截（阅读页 on/off 时调用；设置项持久化后同步）
  static Future<void> setEnabled(bool enabled) async {
    _ensureHooked();
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (_) {
      // 桌面/无通道：忽略
    }
  }
}
