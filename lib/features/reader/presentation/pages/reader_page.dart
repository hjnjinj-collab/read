import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/reader_provider.dart';
import '../widgets/reader_page_widget.dart';
import '../widgets/reader_menu.dart';

class ReaderPage extends ConsumerStatefulWidget {
  final String filePath;
  final String bookName;

  const ReaderPage({
    Key? key,
    required this.filePath,
    required this.bookName,
  }) : super(key: key);

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with WidgetsBindingObserver {
  bool _showMenu = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Open book after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = MediaQuery.of(context).size;
      ref.read(readerProvider.notifier).setScreenSize(size.width, size.height);
      ref.read(readerProvider.notifier).openBook(widget.filePath, widget.bookName);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(readerProvider.notifier).closeBook();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 窗口缩放/拖拽：布局参数必须跟随，否则按旧宽断行的文本与
    // 图片会溢出新画布（截图验证过的错位根因）。
    // 不经 MediaQuery.of(context)——observer 回调里取物理尺寸换算更可靠
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    ref.read(readerProvider.notifier).onWindowResized(size.width, size.height);
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
  }

  void _handleTap(TapUpDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    // Divide screen into 3 zones: left (previous), middle (menu), right (next)
    if (tapX < screenWidth * 0.3) {
      // Left zone - previous page
      ref.read(readerProvider.notifier).previousPage();
    } else if (tapX > screenWidth * 0.7) {
      // Right zone - next page
      ref.read(readerProvider.notifier).nextPage();
    } else {
      // Middle zone - toggle menu
      _toggleMenu();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5DC), // Beige background
      body: SafeArea(
        child: Stack(
          children: [
            // Main reading area
            GestureDetector(
              onTapUp: _handleTap,
              child: Container(
                color: Colors.transparent,
                child: state.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : state.error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Text(
                                'Error: ${state.error}',
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          )
                        : state.currentPage != null
                            ? ReaderPageWidget(
                                pageInfo: state.currentPage!,
                                applyBold: ref.watch(
                                    readerProvider.notifier).boldEnabled,
                                applyItalic: ref.watch(
                                    readerProvider.notifier).italicEnabled,
                                // TXT 章节标题加粗对齐：粗体开关开启且非 EPUB
                                applyTitleBold:
                                    ref.watch(readerProvider.notifier)
                                            .boldEnabled &&
                                        !ref.watch(readerProvider.notifier)
                                            .renderAsEpub,
                              )
                            : const Center(child: Text('No content')),
              ),
            ),

            // Top status bar (always visible)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.3),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      state.bookTitle ?? '',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '${state.currentChapterIndex + 1}/${state.chapters.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom menu (conditional)
            if (_showMenu)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ReaderMenu(
                  onClose: () => setState(() => _showMenu = false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
