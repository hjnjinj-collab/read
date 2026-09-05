import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:legado_flutter/core/services/app_version_service.dart';

/// 关于页面
/// 
/// 显示应用名称、版本号、构建号、简短描述等信息
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versionAsync = ref.watch(appVersionStringProvider);
    final appNameAsync = ref.watch(appNameProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('关于'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 应用图标
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.menu_book,
                  size: 56,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              
              // 应用名称
              appNameAsync.when(
                data: (name) => Text(
                  name,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                loading: () => const CircularProgressIndicator(),
                error: (error, _) => const Text('Legado Flutter'),
              ),
              const SizedBox(height: 8),
              
              // 版本号
              versionAsync.when(
                data: (version) => Text(
                  'Version $version',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                loading: () => const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (error, _) => const Text('Version unknown'),
              ),
              const SizedBox(height: 32),
              
              // 应用简介
              Text(
                '基于 Flutter 的 EPUB/TXT 阅读器',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              
              Text(
                '使用 Rust + Flutter 跨平台架构',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              
              // 功能特性列表
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '主要特性',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildFeatureItem(context, Icons.book, 'EPUB 与 TXT 阅读支持'),
                      _buildFeatureItem(context, Icons.text_fields, '自定义字体、字号、行距'),
                      _buildFeatureItem(context, Icons.view_agenda, '智能分页算法'),
                      _buildFeatureItem(context, Icons.bookmark, '书签与阅读进度保存'),
                      _buildFeatureItem(context, Icons.list, '章节导航'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              
              // 版权信息
              Text(
                '© 2026 Legado Flutter',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureItem(BuildContext context, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
