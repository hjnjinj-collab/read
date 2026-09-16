import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 底栏「添加书籍」请求：自增 token，书架页监听后拉起文件选择。
class ImportRequestNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state = state + 1;
}

final importRequestProvider =
    NotifierProvider<ImportRequestNotifier, int>(ImportRequestNotifier.new);

/// 请求导入（token+1）。书架 keep-alive，切回或已在书架都会响应。
void requestBookImport(WidgetRef ref) {
  ref.read(importRequestProvider.notifier).request();
}
