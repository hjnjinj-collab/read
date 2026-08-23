// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'page_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$PageInfo {

 int get pageIndex; List<LineInfo> get lines; int get startCharIndex; int get endCharIndex;
/// Create a copy of PageInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PageInfoCopyWith<PageInfo> get copyWith => _$PageInfoCopyWithImpl<PageInfo>(this as PageInfo, _$identity);

  /// Serializes this PageInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PageInfo&&(identical(other.pageIndex, pageIndex) || other.pageIndex == pageIndex)&&const DeepCollectionEquality().equals(other.lines, lines)&&(identical(other.startCharIndex, startCharIndex) || other.startCharIndex == startCharIndex)&&(identical(other.endCharIndex, endCharIndex) || other.endCharIndex == endCharIndex));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,pageIndex,const DeepCollectionEquality().hash(lines),startCharIndex,endCharIndex);

@override
String toString() {
  return 'PageInfo(pageIndex: $pageIndex, lines: $lines, startCharIndex: $startCharIndex, endCharIndex: $endCharIndex)';
}


}

/// @nodoc
abstract mixin class $PageInfoCopyWith<$Res>  {
  factory $PageInfoCopyWith(PageInfo value, $Res Function(PageInfo) _then) = _$PageInfoCopyWithImpl;
@useResult
$Res call({
 int pageIndex, List<LineInfo> lines, int startCharIndex, int endCharIndex
});




}
/// @nodoc
class _$PageInfoCopyWithImpl<$Res>
    implements $PageInfoCopyWith<$Res> {
  _$PageInfoCopyWithImpl(this._self, this._then);

  final PageInfo _self;
  final $Res Function(PageInfo) _then;

/// Create a copy of PageInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? pageIndex = null,Object? lines = null,Object? startCharIndex = null,Object? endCharIndex = null,}) {
  return _then(_self.copyWith(
pageIndex: null == pageIndex ? _self.pageIndex : pageIndex // ignore: cast_nullable_to_non_nullable
as int,lines: null == lines ? _self.lines : lines // ignore: cast_nullable_to_non_nullable
as List<LineInfo>,startCharIndex: null == startCharIndex ? _self.startCharIndex : startCharIndex // ignore: cast_nullable_to_non_nullable
as int,endCharIndex: null == endCharIndex ? _self.endCharIndex : endCharIndex // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [PageInfo].
extension PageInfoPatterns on PageInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PageInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PageInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PageInfo value)  $default,){
final _that = this;
switch (_that) {
case _PageInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PageInfo value)?  $default,){
final _that = this;
switch (_that) {
case _PageInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int pageIndex,  List<LineInfo> lines,  int startCharIndex,  int endCharIndex)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PageInfo() when $default != null:
return $default(_that.pageIndex,_that.lines,_that.startCharIndex,_that.endCharIndex);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int pageIndex,  List<LineInfo> lines,  int startCharIndex,  int endCharIndex)  $default,) {final _that = this;
switch (_that) {
case _PageInfo():
return $default(_that.pageIndex,_that.lines,_that.startCharIndex,_that.endCharIndex);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int pageIndex,  List<LineInfo> lines,  int startCharIndex,  int endCharIndex)?  $default,) {final _that = this;
switch (_that) {
case _PageInfo() when $default != null:
return $default(_that.pageIndex,_that.lines,_that.startCharIndex,_that.endCharIndex);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PageInfo implements PageInfo {
  const _PageInfo({required this.pageIndex, required final  List<LineInfo> lines, required this.startCharIndex, required this.endCharIndex}): _lines = lines;
  factory _PageInfo.fromJson(Map<String, dynamic> json) => _$PageInfoFromJson(json);

@override final  int pageIndex;
 final  List<LineInfo> _lines;
@override List<LineInfo> get lines {
  if (_lines is EqualUnmodifiableListView) return _lines;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_lines);
}

@override final  int startCharIndex;
@override final  int endCharIndex;

/// Create a copy of PageInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PageInfoCopyWith<_PageInfo> get copyWith => __$PageInfoCopyWithImpl<_PageInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PageInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PageInfo&&(identical(other.pageIndex, pageIndex) || other.pageIndex == pageIndex)&&const DeepCollectionEquality().equals(other._lines, _lines)&&(identical(other.startCharIndex, startCharIndex) || other.startCharIndex == startCharIndex)&&(identical(other.endCharIndex, endCharIndex) || other.endCharIndex == endCharIndex));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,pageIndex,const DeepCollectionEquality().hash(_lines),startCharIndex,endCharIndex);

@override
String toString() {
  return 'PageInfo(pageIndex: $pageIndex, lines: $lines, startCharIndex: $startCharIndex, endCharIndex: $endCharIndex)';
}


}

/// @nodoc
abstract mixin class _$PageInfoCopyWith<$Res> implements $PageInfoCopyWith<$Res> {
  factory _$PageInfoCopyWith(_PageInfo value, $Res Function(_PageInfo) _then) = __$PageInfoCopyWithImpl;
@override @useResult
$Res call({
 int pageIndex, List<LineInfo> lines, int startCharIndex, int endCharIndex
});




}
/// @nodoc
class __$PageInfoCopyWithImpl<$Res>
    implements _$PageInfoCopyWith<$Res> {
  __$PageInfoCopyWithImpl(this._self, this._then);

  final _PageInfo _self;
  final $Res Function(_PageInfo) _then;

/// Create a copy of PageInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? pageIndex = null,Object? lines = null,Object? startCharIndex = null,Object? endCharIndex = null,}) {
  return _then(_PageInfo(
pageIndex: null == pageIndex ? _self.pageIndex : pageIndex // ignore: cast_nullable_to_non_nullable
as int,lines: null == lines ? _self._lines : lines // ignore: cast_nullable_to_non_nullable
as List<LineInfo>,startCharIndex: null == startCharIndex ? _self.startCharIndex : startCharIndex // ignore: cast_nullable_to_non_nullable
as int,endCharIndex: null == endCharIndex ? _self.endCharIndex : endCharIndex // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$LineInfo {

 String get text; double get x; double get y; double get width;
/// Create a copy of LineInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$LineInfoCopyWith<LineInfo> get copyWith => _$LineInfoCopyWithImpl<LineInfo>(this as LineInfo, _$identity);

  /// Serializes this LineInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is LineInfo&&(identical(other.text, text) || other.text == text)&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y)&&(identical(other.width, width) || other.width == width));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,text,x,y,width);

@override
String toString() {
  return 'LineInfo(text: $text, x: $x, y: $y, width: $width)';
}


}

/// @nodoc
abstract mixin class $LineInfoCopyWith<$Res>  {
  factory $LineInfoCopyWith(LineInfo value, $Res Function(LineInfo) _then) = _$LineInfoCopyWithImpl;
@useResult
$Res call({
 String text, double x, double y, double width
});




}
/// @nodoc
class _$LineInfoCopyWithImpl<$Res>
    implements $LineInfoCopyWith<$Res> {
  _$LineInfoCopyWithImpl(this._self, this._then);

  final LineInfo _self;
  final $Res Function(LineInfo) _then;

/// Create a copy of LineInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? text = null,Object? x = null,Object? y = null,Object? width = null,}) {
  return _then(_self.copyWith(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [LineInfo].
extension LineInfoPatterns on LineInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _LineInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _LineInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _LineInfo value)  $default,){
final _that = this;
switch (_that) {
case _LineInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _LineInfo value)?  $default,){
final _that = this;
switch (_that) {
case _LineInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String text,  double x,  double y,  double width)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _LineInfo() when $default != null:
return $default(_that.text,_that.x,_that.y,_that.width);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String text,  double x,  double y,  double width)  $default,) {final _that = this;
switch (_that) {
case _LineInfo():
return $default(_that.text,_that.x,_that.y,_that.width);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String text,  double x,  double y,  double width)?  $default,) {final _that = this;
switch (_that) {
case _LineInfo() when $default != null:
return $default(_that.text,_that.x,_that.y,_that.width);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _LineInfo implements LineInfo {
  const _LineInfo({required this.text, required this.x, required this.y, required this.width});
  factory _LineInfo.fromJson(Map<String, dynamic> json) => _$LineInfoFromJson(json);

@override final  String text;
@override final  double x;
@override final  double y;
@override final  double width;

/// Create a copy of LineInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$LineInfoCopyWith<_LineInfo> get copyWith => __$LineInfoCopyWithImpl<_LineInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$LineInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _LineInfo&&(identical(other.text, text) || other.text == text)&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y)&&(identical(other.width, width) || other.width == width));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,text,x,y,width);

@override
String toString() {
  return 'LineInfo(text: $text, x: $x, y: $y, width: $width)';
}


}

/// @nodoc
abstract mixin class _$LineInfoCopyWith<$Res> implements $LineInfoCopyWith<$Res> {
  factory _$LineInfoCopyWith(_LineInfo value, $Res Function(_LineInfo) _then) = __$LineInfoCopyWithImpl;
@override @useResult
$Res call({
 String text, double x, double y, double width
});




}
/// @nodoc
class __$LineInfoCopyWithImpl<$Res>
    implements _$LineInfoCopyWith<$Res> {
  __$LineInfoCopyWithImpl(this._self, this._then);

  final _LineInfo _self;
  final $Res Function(_LineInfo) _then;

/// Create a copy of LineInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? text = null,Object? x = null,Object? y = null,Object? width = null,}) {
  return _then(_LineInfo(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

// dart format on
