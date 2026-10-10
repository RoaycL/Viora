// Web 预览用的空实现：Web 不支持 dart:ffi，聚合索引不可用（MediaIndex.open 在 Web 上返回 null）。
// 只为让 Web 能编译；Windows / Android 使用 package:sqlite3。

class _Sqlite3 {
  Database open(String path) => throw UnsupportedError('Web 不支持本地索引');
  Database openInMemory() => throw UnsupportedError('Web 不支持本地索引');
}

final sqlite3 = _Sqlite3();

abstract class Row {
  Object? operator [](String column);
}

abstract class PreparedStatement {
  void execute([List<Object?> parameters = const []]);
  void close();
}

abstract class Database {
  void execute(String sql, [List<Object?> parameters = const []]);
  List<Row> select(String sql, [List<Object?> parameters = const []]);
  PreparedStatement prepare(String sql);
  void close();
}
