// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'chapter.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Chapter {

 String get title; int get startPos; int get endPos;
/// Create a copy of Chapter
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChapterCopyWith<Chapter> get copyWith => _$ChapterCopyWithImpl<Chapter>(this as Chapter, _$identity);

  /// Serializes this Chapter to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Chapter&&(identical(other.title, title) || other.title == title)&&(identical(other.startPos, startPos) || other.startPos == startPos)&&(identical(other.endPos, endPos) || other.endPos == endPos));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,title,startPos,endPos);

@override
String toString() {
  return 'Chapter(title: $title, startPos: $startPos, endPos: $endPos)';
}


}

/// @nodoc
abstract mixin class $ChapterCopyWith<$Res>  {
  factory $ChapterCopyWith(Chapter value, $Res Function(Chapter) _then) = _$ChapterCopyWithImpl;
@useResult
$Res call({
 String title, int startPos, int endPos
});




}
/// @nodoc
class _$ChapterCopyWithImpl<$Res>
    implements $ChapterCopyWith<$Res> {
  _$ChapterCopyWithImpl(this._self, this._then);

  final Chapter _self;
  final $Res Function(Chapter) _then;

/// Create a copy of Chapter
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? title = null,Object? startPos = null,Object? endPos = null,}) {
  return _then(_self.copyWith(
title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,startPos: null == startPos ? _self.startPos : startPos // ignore: cast_nullable_to_non_nullable
as int,endPos: null == endPos ? _self.endPos : endPos // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [Chapter].
extension ChapterPatterns on Chapter {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Chapter value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Chapter() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Chapter value)  $default,){
final _that = this;
switch (_that) {
case _Chapter():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Chapter value)?  $default,){
final _that = this;
switch (_that) {
case _Chapter() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String title,  int startPos,  int endPos)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Chapter() when $default != null:
return $default(_that.title,_that.startPos,_that.endPos);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String title,  int startPos,  int endPos)  $default,) {final _that = this;
switch (_that) {
case _Chapter():
return $default(_that.title,_that.startPos,_that.endPos);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String title,  int startPos,  int endPos)?  $default,) {final _that = this;
switch (_that) {
case _Chapter() when $default != null:
return $default(_that.title,_that.startPos,_that.endPos);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Chapter implements Chapter {
  const _Chapter({required this.title, required this.startPos, required this.endPos});
  factory _Chapter.fromJson(Map<String, dynamic> json) => _$ChapterFromJson(json);

@override final  String title;
@override final  int startPos;
@override final  int endPos;

/// Create a copy of Chapter
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ChapterCopyWith<_Chapter> get copyWith => __$ChapterCopyWithImpl<_Chapter>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ChapterToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Chapter&&(identical(other.title, title) || other.title == title)&&(identical(other.startPos, startPos) || other.startPos == startPos)&&(identical(other.endPos, endPos) || other.endPos == endPos));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,title,startPos,endPos);

@override
String toString() {
  return 'Chapter(title: $title, startPos: $startPos, endPos: $endPos)';
}


}

/// @nodoc
abstract mixin class _$ChapterCopyWith<$Res> implements $ChapterCopyWith<$Res> {
  factory _$ChapterCopyWith(_Chapter value, $Res Function(_Chapter) _then) = __$ChapterCopyWithImpl;
@override @useResult
$Res call({
 String title, int startPos, int endPos
});




}
/// @nodoc
class __$ChapterCopyWithImpl<$Res>
    implements _$ChapterCopyWith<$Res> {
  __$ChapterCopyWithImpl(this._self, this._then);

  final _Chapter _self;
  final $Res Function(_Chapter) _then;

/// Create a copy of Chapter
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? title = null,Object? startPos = null,Object? endPos = null,}) {
  return _then(_Chapter(
title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,startPos: null == startPos ? _self.startPos : startPos // ignore: cast_nullable_to_non_nullable
as int,endPos: null == endPos ? _self.endPos : endPos // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
