import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用版本信息服务 Provider
/// 
/// 封装 PackageInfo.fromPlatform() 调用，提供版本号、构建号、应用名等字段
final appVersionServiceProvider = FutureProvider<PackageInfo>((ref) async {
  return await PackageInfo.fromPlatform();
});

/// 便捷的版本字符串 Provider（格式：1.0.0+1）
final appVersionStringProvider = FutureProvider<String>((ref) async {
  final packageInfo = await ref.watch(appVersionServiceProvider.future);
  return '${packageInfo.version}+${packageInfo.buildNumber}';
});

/// 便捷的版本号 Provider（格式：1.0.0）
final appVersionProvider = FutureProvider<String>((ref) async {
  final packageInfo = await ref.watch(appVersionServiceProvider.future);
  return packageInfo.version;
});

/// 便捷的构建号 Provider
final appBuildNumberProvider = FutureProvider<String>((ref) async {
  final packageInfo = await ref.watch(appVersionServiceProvider.future);
  return packageInfo.buildNumber;
});

/// 便捷的应用名称 Provider
final appNameProvider = FutureProvider<String>((ref) async {
  final packageInfo = await ref.watch(appVersionServiceProvider.future);
  return packageInfo.appName;
});
