import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'core/database/app_database.dart';
import 'core/database/app_settings_service.dart';
import 'core/ffi/book_service.dart';
import 'core/router/app_router.dart';
import 'core/services/reader_font.dart';
import 'core/theme/app_theme.dart';
import 'features/reader/presentation/providers/reader_provider.dart';
import 'features/reader/presentation/providers/reader_settings.dart';
import 'features/reader/presentation/widgets/page_turn_composer.dart';
import 'features/shell/providers/shell_settings.dart';

/// P6：清掉自定义字体持久化（副本丢失/恢复失败时回退内置），其余设置原样保留
void _clearCustomFontPersisted() {
  final raw = AppSettingsService.instance.raw('reader') ?? '';
  final map = jsonDecode(raw.isEmpty ? '{}' : raw);
  if (map is Map<String, dynamic>) {
    map['customFontFamily'] = '';
    map['customFontPath'] = '';
    AppSettingsService.instance.save('reader', jsonEncode(map));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BookService.init();
  await ReaderFont.initialize();
  await initCoverCacheDir();
  await initHotPageCacheDir();

  final db = AppDatabase();
  await AppSettingsService.instance.load(db);
  final settings = ReaderSettings.tryParse(
      AppSettingsService.instance.raw('reader'));

  // 液态/毛玻璃引擎开关须在首个 Lens 构建前生效
  ShellSettings.tryParse(AppSettingsService.instance.raw(ShellSettings.storageKey))
      .applyGlassEngine();

  unawaited(PageTurnComposerState.preloadShaders());
  // 液态模式预编译 lens shader；Windows/lite 下跳过，避免 Impeller GL 崩进程
  if (!Platform.isWindows) {
    unawaited(() async {
      try {
        await LiquidGlassShaders.ensureLoaded();
      } catch (e) {
        debugPrint('liquid_glass shader preload skipped: $e');
      }
    }());
  }

  if (settings.customFontFamily.isNotEmpty &&
      settings.customFontPath.isNotEmpty) {
    final f = File(settings.customFontPath);
    if (f.existsSync()) {
      try {
        final bytes = await f.readAsBytes();
        await ReaderFont.loadCustomFont(
          name: settings.customFontFamily,
          bytes: bytes,
          displayLabel: settings.customFontFamily,
        );
      } catch (e) {
        debugPrint('✗ 自定义字体恢复失败，回退内置: $e');
        _clearCustomFontPersisted();
      }
    } else {
      _clearCustomFontPersisted();
    }
  }

  try {
    await BookService().setParagraphFormatSettings(
      enableIndent: settings.enableIndent,
      indentSizeChars: settings.indentSizeChars,
      paragraphSpacingMultiplier: settings.paragraphSpacingMultiplier,
      reParagraphMode: settings.reParagraphMode,
      smartSplitThreshold: settings.smartSplitThreshold,
      aggressiveSplitThreshold: settings.aggressiveSplitThreshold,
      justify: settings.justify,
      punctuationCompress: settings.punctuationCompress,
      commentScale: settings.commentScale,
    );
  } catch (_) {}

  runApp(ProviderScope(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
    child: const MyApp(),
  ));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final dynamicOn = ref.watch(
      shellSettingsProvider.select((s) => s.dynamicColor),
    );
    final themeMode = ref.watch(
      shellSettingsProvider.select((s) => s.resolvedThemeMode),
    );
    final seedOverride = ref.watch(
      shellSettingsProvider.select((s) => s.seedArgb),
    );

    return FutureBuilder<({Color? light, Color? dark})>(
      future: dynamicOn
          ? _loadDynamicSeeds()
          : Future.value((light: null, dark: null)),
      builder: (context, snapshot) {
        final lightSeed = snapshot.data?.light;
        final darkSeed = snapshot.data?.dark;
        final custom =
            seedOverride != null ? Color(seedOverride) : null;
        return MaterialApp.router(
          title: 'Legado Flutter',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(
            dynamicSeed: lightSeed,
            seedOverride: custom,
          ),
          darkTheme: AppTheme.dark(
            dynamicSeed: darkSeed,
            seedOverride: custom,
          ),
          themeMode: themeMode,
          routerConfig: router,
        );
      },
    );
  }

  /// 只取壁纸 primary 作为 seed，再用 Flutter ColorScheme.fromSeed 派生，
  /// 避免 material_ui.ColorScheme 与 framework ColorScheme 类型分叉。
  Future<({Color? light, Color? dark})> _loadDynamicSeeds() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette == null) {
        return (light: null, dark: null);
      }
      return (
        light: Color(palette.primary.get(40)),
        dark: Color(palette.primary.get(80)),
      );
    } catch (_) {
      return (light: null, dark: null);
    }
  }
}
