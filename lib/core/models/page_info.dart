import 'package:freezed_annotation/freezed_annotation.dart';

part 'page_info.freezed.dart';
part 'page_info.g.dart';

@freezed
sealed class PageInfo with _$PageInfo {
  const factory PageInfo({
    required int pageIndex,
    required List<LineInfo> lines,
    required int startCharIndex,
    required int endCharIndex,
  }) = _PageInfo;

  factory PageInfo.fromJson(Map<String, dynamic> json) =>
      _$PageInfoFromJson(json);
}

@freezed
sealed class LineInfo with _$LineInfo {
  const factory LineInfo({
    required String text,
    required double x,
    required double y,
    required double width,
  }) = _LineInfo;

  factory LineInfo.fromJson(Map<String, dynamic> json) =>
      _$LineInfoFromJson(json);
}
