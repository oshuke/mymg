/// 字符串工具：解析异常成"用户可读"的短串。
///
/// FlutterRustBridge 把 Rust 抛出的 `Err(String)` 在 Dart 端重新包装成
/// `Exception('xxx')` 抛出，`e.toString()` 返回 `"Exception: xxx"`。
/// 这个 helper 去掉前面那串多余前缀，避免用户看到 "Exception: 网络请求失败: ..."，
/// 但保留原始业务信息（HTTP 错误码、JSON 错误、err_resp 描述等）。
String formatFrbError(Object e) {
  var s = e.toString();
  if (s.startsWith('Exception: ')) s = s.substring('Exception: '.length);
  if (s.startsWith('Error: ')) s = s.substring('Error: '.length);
  return s;
}
