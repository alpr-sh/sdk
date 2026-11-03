import 'json.dart';
import 'models.dart';

/// One page of a list, and where the list ends.
final class Page<T> {
  const Page({required this.items, required this.pagination});

  /// A page out of the API's JSON, each item read by [item].
  factory Page.fromJson(
    Map<String, Object?> json,
    T Function(Map<String, Object?> json) item,
  ) => Page(
    items: json['items'] == null
        ? const []
        : readList(json['items'], (value) => item(readObject(value))),
    pagination: Pagination.fromJson(readObject(json['pagination'])),
  );

  /// The items of this page.
  final List<T> items;

  /// How many items and pages the list has.
  final Pagination pagination;
}

/// Walks pages from [first] until the last one, as Polar's SDKs do, giving
/// every item. An error ends the walk.
Stream<T> iterate<T>(
  Future<Page<T>> Function(int page) fetch, [
  int first = 1,
]) async* {
  for (var page = first < 1 ? 1 : first; ; page++) {
    final result = await fetch(page);
    for (final item in result.items) {
      yield item;
    }
    if (page >= result.pagination.maxPage) {
      return;
    }
  }
}
