import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// 书籍记录（书架条目）
///
/// 以 filePath 为稳定身份键：book_id 每次解析重新生成，
/// 跨启动恢复只能依赖文件路径。
class Books extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get filePath => text().unique()();
  TextColumn get title => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastReadAt => dateTime().nullable()();
}

/// 阅读进度（每本书一条，upsert）
///
/// charOffset 为章内字符锚点（页面 startCharIndex），
/// 重开时经 locate_page_for_offset 精确回到原阅读位置（债#2/#3）。
class ReadingProgress extends Table {
  TextColumn get bookPath => text()();
  IntColumn get chapterIndex => integer()();
  IntColumn get charOffset => integer()();
  IntColumn get totalChapters => integer()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {bookPath};
}

/// 书签
class Bookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookPath => text()();
  IntColumn get chapterIndex => integer()();
  /// 章内字符偏移：书签跳转与进度同一套锚点机制
  IntColumn get charOffset => integer()();
  /// 创建时的摘录（用于书签列表辨识）
  TextColumn get preview => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [Books, ReadingProgress, Bookmarks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  // ===== 书架 =====

  Future<List<Book>> allBooksByLastRead() {
    return (select(books)
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.lastReadAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.addedAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  /// 书架登记（按身份键 filePath 定向 upsert）
  ///
  /// book_id 每次解析重新生成（自增 id 恒为新值），因此冲突只会发生在
  /// filePath 的 UNIQUE 约束上——必须显式指定 target: [books.filePath]，
  /// 否则 ON CONFLICT("id") 不生效，重开任何已入库书籍都会抛
  /// UNIQUE constraint failed: books.file_path（错误码 2067）。
  Future<void> upsertBook(String filePath, String title) async {
    await into(books).insert(
      BooksCompanion.insert(
        filePath: filePath,
        title: title,
        lastReadAt: Value(DateTime.now()),
      ),
      onConflict: DoUpdate(
        (old) => BooksCompanion(
          title: Value(title),
          lastReadAt: Value(DateTime.now()),
        ),
        target: [books.filePath],
      ),
    );
  }

  Future<void> touchLastRead(String filePath) async {
    await (update(books)..where((b) => b.filePath.equals(filePath))).write(
      BooksCompanion(lastReadAt: Value(DateTime.now())),
    );
  }

  Future<int> deleteBook(String filePath) {
    return (delete(books)..where((b) => b.filePath.equals(filePath))).go();
  }

  Future<int> deleteProgress(String bookPath) {
    return (delete(readingProgress)..where((r) => r.bookPath.equals(bookPath)))
        .go();
  }

  Future<int> deleteBookmarks(String bookPath) {
    return (delete(bookmarks)..where((m) => m.bookPath.equals(bookPath))).go();
  }

  // ===== 阅读进度 =====

  Future<ReadingProgressData?> progressOf(String bookPath) {
    return (select(readingProgress)..where((r) => r.bookPath.equals(bookPath)))
        .getSingleOrNull();
  }

  Future<void> saveProgress({
    required String bookPath,
    required int chapterIndex,
    required int charOffset,
    required int totalChapters,
  }) async {
    await into(readingProgress).insertOnConflictUpdate(
      ReadingProgressCompanion.insert(
        bookPath: bookPath,
        chapterIndex: chapterIndex,
        charOffset: charOffset,
        totalChapters: totalChapters,
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  // ===== 书签 =====

  Future<List<Bookmark>> bookmarksOf(String bookPath) {
    return (select(bookmarks)
          ..where((m) => m.bookPath.equals(bookPath))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
        .get();
  }

  Future<int> addBookmark({
    required String bookPath,
    required int chapterIndex,
    required int charOffset,
    required String preview,
  }) {
    return into(bookmarks).insert(BookmarksCompanion.insert(
      bookPath: bookPath,
      chapterIndex: chapterIndex,
      charOffset: charOffset,
      preview: preview,
    ));
  }

  Future<int> deleteBookmark(int id) {
    return (delete(bookmarks)..where((m) => m.id.equals(id))).go();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'legado.sqlite3'));
    return NativeDatabase.createInBackground(file);
  });
}
