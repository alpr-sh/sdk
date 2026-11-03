import 'json.dart';

/// One page of a list: its items, and the cursor of the next page.
final class Page<T> {
  const Page({required this.items, this.next});

  /// A page out of the API's JSON, each item read by [item].
  factory Page.fromJson(
    Map<String, Object?> json,
    T Function(Map<String, Object?> json) item,
  ) {
    return Page(
      items: readList(json['data'], (value) => item(readObject(value))),
      next: json['next'] as String?,
    );
  }

  /// The items of this page.
  final List<T> items;

  /// The cursor to ask the next page with; null on the last page.
  final String? next;
}

/// Walks pages from the cursor [first] (the newest page when null) until the
/// last one, giving every item. An error ends the walk.
Stream<T> iterate<T>(
  Future<Page<T>> Function(String? cursor) fetch, [
  String? first,
]) async* {
  var cursor = first;
  while (true) {
    final result = await fetch(cursor);
    for (final item in result.items) {
      yield item;
    }
    final next = result.next;
    // A cursor that does not move would ask for the same page forever.
    if (next == null || next.isEmpty || next == cursor) {
      return;
    }
    cursor = next;
  }
}
