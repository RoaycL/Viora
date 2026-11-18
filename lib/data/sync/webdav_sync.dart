import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';

import '../config/app_config.dart';

class WebDavException implements Exception {
  const WebDavException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 条件写入失败：读取后另一台设备已经修改了云端文件。
class WebDavConflict extends WebDavException {
  const WebDavConflict() : super('云端配置已被其他设备修改，请重新同步');
}

/// 最简 WebDAV 客户端：只用到 PROPFIND（测试连接）、MKCOL（建目录）、GET / PUT（读写配置文件）
class WebDavClient {
  WebDavClient(this.config, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
            ),
          );

  final WebDavConfig config;
  final Dio _dio;

  Uri get _base {
    var url = config.url.trim();
    if (!url.contains('://')) url = 'https://$url';
    return Uri.parse(url.endsWith('/') ? url : '$url/');
  }

  List<String> get _segments => config.path.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  Uri get fileUri => _base.resolve(_segments.map(Uri.encodeComponent).join('/'));

  Map<String, String> get _headers => {
    if (config.username.isNotEmpty || config.password.isNotEmpty)
      'Authorization': 'Basic ${base64.encode(utf8.encode('${config.username}:${config.password}'))}',
    'User-Agent': 'Viora',
  };

  Never _fail(String action, int? status) {
    throw WebDavException(switch (status) {
      401 => 'WebDAV 用户名或密码错误（$action：HTTP 401）',
      403 => 'WebDAV 拒绝访问（$action：HTTP 403），请检查账号权限或路径',
      404 => 'WebDAV 路径不存在（$action：HTTP 404），请检查地址',
      507 => 'WebDAV 空间不足（$action：HTTP 507）',
      _ => 'WebDAV $action失败（HTTP $status）',
    });
  }

  Future<Response<String>> _send(String method, Uri uri, {Object? data, Map<String, String>? headers}) async {
    try {
      return await _dio.requestUri<String>(
        uri,
        data: data,
        options: Options(method: method, headers: {..._headers, ...?headers}),
      );
    } on DioException catch (e) {
      throw WebDavException('连不上 WebDAV（${_base.host}）：${e.message ?? e.type.name}');
    }
  }

  /// 测试地址和账号
  Future<void> test() async {
    final r = await _send('PROPFIND', _base, headers: {'Depth': '0'});
    if (r.statusCode != 207 && r.statusCode != 200) _fail('连接', r.statusCode);
  }

  /// 读取内容和同一次响应的 ETag，供条件写入使用。
  Future<({String content, String? etag})?> readFile() async {
    final r = await _send('GET', fileUri);
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail('读取', r.statusCode);
    return (content: r.data ?? '', etag: r.headers.value('etag'));
  }

  Future<String?> read() async => (await readFile())?.content;

  /// 写入配置文件（目录不存在时逐级创建）
  Future<void> write(String content, {String? ifMatch, bool ifNoneMatch = false}) async {
    final body = utf8.encode(content);
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': '${body.length}',
      'If-Match': ?ifMatch,
      if (ifNoneMatch) 'If-None-Match': '*',
    };
    var r = await _send('PUT', fileUri, data: Stream.fromIterable([body]), headers: headers);
    // 父目录不存在：多数服务器回 409 / 404，有的（如部分 Nginx、Alist 挂载）回 405。建好目录再试一次
    if (r.statusCode == 409 || r.statusCode == 404 || r.statusCode == 405) {
      final dirs = _segments.take(_segments.length - 1).toList();
      for (var i = 1; i <= dirs.length; i++) {
        final m = await _send('MKCOL', _base.resolve('${dirs.take(i).map(Uri.encodeComponent).join('/')}/'));
        // 201 新建；405 已存在
        if (m.statusCode != 201 && m.statusCode != 405 && m.statusCode != 200) _fail('创建目录', m.statusCode);
      }
      r = await _send('PUT', fileUri, data: Stream.fromIterable([body]), headers: headers);
    }
    if (r.statusCode == 412) throw const WebDavConflict();
    if (r.statusCode == 405) {
      throw const WebDavException(
        'WebDAV 不允许在这个位置写文件（HTTP 405）：目录可能是只读的（如 Alist 的只读存储、网盘挂载的根目录），'
        '请把「文件路径」换到可写的目录，或检查账号的写入权限',
      );
    }
    if (r.statusCode != 200 && r.statusCode != 201 && r.statusCode != 204) _fail('上传', r.statusCode);
  }
}

/// 云端文件的加密（可选）：PBKDF2-SHA256 派生密钥 + AES-256-GCM
abstract final class WebDavCrypto {
  static const _iterations = 60000;

  static Future<SecretKey> _key(String passphrase, List<int> salt, int iterations) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  ).deriveKeyFromPassword(password: passphrase, nonce: salt);

  static Future<Map<String, dynamic>> encrypt(Map<String, dynamic> payload, String passphrase) async {
    final aes = AesGcm.with256bits();
    final salt = aes.newNonce() + aes.newNonce();
    final key = await _key(passphrase, salt, _iterations);
    final box = await aes.encrypt(utf8.encode(jsonEncode(payload)), secretKey: key);
    return {
      'viora': payload['viora'],
      'encrypted': {
        'alg': 'AES-256-GCM',
        'kdf': 'PBKDF2-SHA256',
        'iterations': _iterations,
        'salt': base64.encode(salt),
        'nonce': base64.encode(box.nonce),
        'data': base64.encode(box.cipherText),
        'mac': base64.encode(box.mac.bytes),
      },
    };
  }

  static bool isEncrypted(Map<String, dynamic> file) => file['encrypted'] is Map;

  /// 解密；口令不对抛 [WebDavException]
  static Future<Map<String, dynamic>> decrypt(Map<String, dynamic> file, String passphrase) async {
    final e = file['encrypted'] as Map<String, dynamic>;
    if (passphrase.isEmpty) throw const WebDavException('云端配置已加密，请填写加密口令');
    final key = await _key(passphrase, base64.decode(e['salt'] as String), e['iterations'] as int? ?? _iterations);
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64.decode(e['data'] as String),
          nonce: base64.decode(e['nonce'] as String),
          mac: Mac(base64.decode(e['mac'] as String)),
        ),
        secretKey: key,
      );
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } on SecretBoxAuthenticationError {
      throw const WebDavException('加密口令不对，无法解密云端配置');
    }
  }
}
