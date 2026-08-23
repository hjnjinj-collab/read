// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'page_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_PageInfo _$PageInfoFromJson(Map<String, dynamic> json) => _PageInfo(
  pageIndex: (json['pageIndex'] as num).toInt(),
  lines: (json['lines'] as List<dynamic>)
      .map((e) => LineInfo.fromJson(e as Map<String, dynamic>))
      .toList(),
  startCharIndex: (json['startCharIndex'] as num).toInt(),
  endCharIndex: (json['endCharIndex'] as num).toInt(),
);

Map<String, dynamic> _$PageInfoToJson(_PageInfo instance) => <String, dynamic>{
  'pageIndex': instance.pageIndex,
  'lines': instance.lines,
  'startCharIndex': instance.startCharIndex,
  'endCharIndex': instance.endCharIndex,
};

_LineInfo _$LineInfoFromJson(Map<String, dynamic> json) => _LineInfo(
  text: json['text'] as String,
  x: (json['x'] as num).toDouble(),
  y: (json['y'] as num).toDouble(),
  width: (json['width'] as num).toDouble(),
);

Map<String, dynamic> _$LineInfoToJson(_LineInfo instance) => <String, dynamic>{
  'text': instance.text,
  'x': instance.x,
  'y': instance.y,
  'width': instance.width,
};
