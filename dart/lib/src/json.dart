// Readers the generated models build themselves with. A value of the wrong
// type fails loudly, as a TypeError.

/// [value] as a JSON object.
Map<String, Object?> readObject(Object? value) => value as Map<String, Object?>;

/// [value] as a string.
String readString(Object? value) => value as String;

/// [value] as an integer.
int readInt(Object? value) => value as int;

/// [value] as a number.
double readDouble(Object? value) => (value as num).toDouble();

/// [value] as a boolean.
bool readBool(Object? value) => value as bool;

/// [value] as a list, each item read by [read].
List<T> readList<T>(Object? value, T Function(Object? value) read) =>
    List.unmodifiable((value as List<Object?>).map(read));

/// [value] as a map, each value read by [read].
Map<String, T> readMap<T>(Object? value, T Function(Object? value) read) =>
    Map.unmodifiable(
      readObject(value).map((key, each) => MapEntry(key, read(each))),
    );

/// [value] read by [read], or null.
T? readOptional<T extends Object>(
  Object? value,
  T Function(Object? value) read,
) => value == null ? null : read(value);
