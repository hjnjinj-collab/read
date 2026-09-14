import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/app_version_service.dart';
import '../../core/theme/app_icons.dart';
import 'providers/shell_settings.dart';

/// 设置 Tab：布局 / 动态取色 / 版本 / 关于
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellSettingsProvider);
    final shellNotifier = ref.read(shellSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final versionAsync = ref.watch(appVersionStringProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(
            title: Text('设置'),
          ),
          SliverList.list(
            children: [
              _SectionHeader(label: '外观'),
              SwitchListTile(
                title: const Text('动态取色'),
                subtitle: const Text('Android 12+ 跟随壁纸（默认关闭，保持纸墨气质）'),
                value: shell.dynamicColor,
                onChanged: shellNotifier.setDynamicColor,
              ),
              SwitchListTile(
                title: const Text('书架网格布局'),
                subtitle: const Text('关闭则使用列表模式'),
                value: shell.bookshelfGrid,
                onChanged: shellNotifier.setBookshelfGrid,
              ),
              const Divider(height: 24),
              _SectionHeader(label: '关于'),
              ListTile(
                leading: Icon(AppIcons.about, color: scheme.onSurfaceVariant),
                title: const Text('关于'),
                subtitle: versionAsync.when(
                  data: (v) => Text('版本 $v'),
                  loading: () => const Text('读取中…'),
                  error: (_, _) => const Text('版本未知'),
                ),
                trailing: const Icon(AppIcons.chevronRight),
                onTap: () => context.push('/about'),
              ),
              const SizedBox(height: 120),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
