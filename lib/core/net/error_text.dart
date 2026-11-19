import 'package:dio/dio.dart';

/// 界面上显示的错误说明：网络请求的错误换成中文短句，不显示 Dio 的英文长段说明
String errorText(Object error) {
  if (error is! DioException) return error.toString();
  final status = error.response?.statusCode;
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.sendTimeout => '连接超时，请检查网络',
    DioExceptionType.connectionError => '无法连接，请检查网络或代理',
    DioExceptionType.badCertificate => '证书无效',
    DioExceptionType.badResponse when status == 401 || status == 403 => '没有权限（HTTP $status），请检查登录或 Key',
    DioExceptionType.badResponse when status == 404 => '找不到这个条目（HTTP 404）',
    DioExceptionType.badResponse when status != null && status >= 500 => '服务暂时无法响应（HTTP $status），稍后重试',
    DioExceptionType.badResponse => '请求失败（HTTP $status）',
    DioExceptionType.cancel => '请求已取消',
    _ => '网络错误',
  };
}
