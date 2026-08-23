// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chapter.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Chapter _$ChapterFromJson(Map<String, dynamic> json) => _Chapter(
  title: json['title'] as String,
  startPos: (json['startPos'] as num).toInt(),
  endPos: (json['endPos'] as num).toInt(),
);

Map<String, dynamic> _$ChapterToJson(_Chapter instance) => <String, dynamic>{
  'title': instance.title,
  'startPos': instance.startPos,
  'endPos': instance.endPos,
};
