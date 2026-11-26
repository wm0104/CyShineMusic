import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../api/dio_factory.dart';
import 'package:html_unescape/html_unescape.dart';
import 'sync_models.dart';
import 'webdav_config_store.dart';

class WebDavException implements Exception {
  const WebDavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class WebDavRemoteSnapshot {
  const WebDavRemoteSnapshot({required this.snapshot, this.etag});

  final WebDavSyncSnapshot snapshot;
  final String? etag;
}

class WebDavClient {
  WebDavClient(this.config, {Dio? dio}) : _dio = dio ?? _createDio();

  final WebDavSyncConfig config;
  final Dio _dio;

  Uri get directoryUri => Uri.parse('${config.baseUrl}/CyShineMusic');
  Uri get snapshotUri => Uri.parse('${directoryUri.toString()}/sync-v1.json');

  static Dio _createDio() => createDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.plain,
      validateStatus: (status) => status != null && status < 600,
    ),
  );

  Future<WebDavRemoteSnapshot?> connectAndRead() async {
    await ensureDirectory();
    return read();
  }

  Future<void> ensureDirectory() async {
    final response = await _request(
      directoryUri.toString(),
      options: Options(method: 'MKCOL'),
    );
    final status = response.statusCode ?? 0;
    if (status == 200 || status == 201 || status == 204 || status == 405) {
      return;
    }
    throw _statusException(status);
  }

  Future<WebDavRemoteSnapshot?> read() async {
    final response = await _request(
      snapshotUri.toString(),
      options: Options(method: 'GET', responseType: ResponseType.plain),
    );
    final status = response.statusCode ?? 0;
    if (status == 404) return null;
    if (status < 200 || status >= 300) throw _statusException(status);
    final body = response.data?.toString() ?? '';
    return WebDavRemoteSnapshot(
      snapshot: WebDavSyncSnapshot.decode(body),
      etag: response.headers.value('etag'),
    );
  }

  Future<String?> write(
    WebDavSyncSnapshot snapshot, {
    String? etag,
    bool createOnly = false,
  }) async {
    final headers = <String, Object>{'Content-Type': 'application/json'};
    if (etag != null && etag.isNotEmpty) headers['If-Match'] = etag;
    if (createOnly) headers['If-None-Match'] = '*';
    final response = await _request(
      snapshotUri.toString(),
      data: snapshot.encode(),
      options: Options(method: 'PUT', headers: headers),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) throw _statusException(status);
    return response.headers.value('etag');
  }

  Future<Response<dynamic>> _request(
    String url, {
    Object? data,
    required Options options,
  }) async {
    final headers = <String, Object>{...?options.headers};
    if (config.username.isNotEmpty || config.password.isNotEmpty) {
      final credentials = base64Encode(
        utf8.encode('${config.username}:${config.password}'),
      );
      headers['Authorization'] = 'Basic $credentials';
    }
    try {
      return await _dio.request<dynamic>(
        url,
        data: data,
        options: options.copyWith(headers: headers),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        throw const WebDavException('连接 WebDAV 超时');
      }
      throw WebDavException('无法连接 WebDAV：${error.message ?? '网络错误'}');
    }
  }

  WebDavException _statusException(int status) {
    return switch (status) {
      401 || 403 => WebDavException('WebDAV 用户名、密码或权限不正确', statusCode: status),
      409 => WebDavException('WebDAV 目录无法创建，请检查地址', statusCode: status),
      412 => WebDavException('云端数据已被其他设备更新', statusCode: status),
      _ => WebDavException('WebDAV 请求失败（HTTP $status）', statusCode: status),
    };
  }

  Uri get backupDirectoryUri => Uri.parse('${directoryUri.toString()}/playlist-backups');

  Uri _backupUri(String name) {
    if (_backupNameOrder(name) == null) {
      throw const FormatException('备份文件名称无效');
    }
    return Uri.parse('${backupDirectoryUri.toString()}/$name');
  }

  Future<void> uploadPlaylistBackup(String name, String text) async {
    final uri = _backupUri(name);
    await ensureDirectory();
    final directory = await _request(backupDirectoryUri.toString(), options: Options(method: 'MKCOL'));
    final status = directory.statusCode ?? 0;
    if (status != 200 && status != 201 && status != 204 && status != 405) {
      throw _statusException(status);
    }
    final response = await _request(uri.toString(), data: text, options: Options(
      method: 'PUT', headers: {'Content-Type': 'application/json; charset=utf-8', 'If-None-Match': '*'},
    ));
    final code = response.statusCode ?? 0;
    if (code < 200 || code >= 300) throw _statusException(code);
  }

  Future<List<String>> listPlaylistBackups() async {
    final response = await _request('${backupDirectoryUri.toString()}/',
      data: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getlastmodified/></d:prop></d:propfind>',
      options: Options(method: 'PROPFIND', headers: {'Depth': '1', 'Content-Type': 'application/xml'}, responseType: ResponseType.plain),
    );
    final status = response.statusCode ?? 0;
    if (status == 404) return const [];
    if (status != 207 && status != 200) throw _statusException(status);
    final body = response.data?.toString() ?? '';
    final names = <String, int>{};
    final responses = RegExp(r'<(?:[\w.-]+:)?response\b[^>]*>([\s\S]*?)</(?:[\w.-]+:)?response\s*>', caseSensitive: false);
    final hrefs = RegExp(r'<(?:[\w.-]+:)?href\b[^>]*>([\s\S]*?)</(?:[\w.-]+:)?href\s*>', caseSensitive: false);
    final modified = RegExp(r'<(?:[\w.-]+:)?getlastmodified\b[^>]*>([\s\S]*?)</(?:[\w.-]+:)?getlastmodified\s*>', caseSensitive: false);
    for (final entry in responses.allMatches(body)) {
      final properties = entry.group(1)!;
      final match = hrefs.firstMatch(properties);
      if (match == null) continue;
      final href = HtmlUnescape().convert(match.group(1)!.trim());
      final uri = Uri.parse('${backupDirectoryUri.toString()}/').resolve(href);
      if (uri.host != backupDirectoryUri.host || uri.scheme != backupDirectoryUri.scheme || uri.port != backupDirectoryUri.port) continue;
      final prefix = '${backupDirectoryUri.path}/';
      if (!uri.path.startsWith(prefix)) continue;
      final name = Uri.decodeComponent(uri.path.substring(prefix.length));
      final order = _backupNameOrder(name);
      if (order == null) continue;
      var time = order.time;
      final value = modified.firstMatch(properties)?.group(1)?.trim();
      if (value != null) {
        try {
          time = HttpDate.parse(HtmlUnescape().convert(value)).microsecondsSinceEpoch;
        } on Exception {
          // Some servers omit or misformat this optional property.
        }
      }
      if (!names.containsKey(name) || time > names[name]!) names[name] = time;
    }
    return names.keys.toList()..sort((a, b) {
      final time = names[b]!.compareTo(names[a]!);
      if (time != 0) return time;
      final number = _backupNameOrder(b)!.number.compareTo(_backupNameOrder(a)!.number);
      return number != 0 ? number : b.compareTo(a);
    });
  }

  ({int time, int number})? _backupNameOrder(String name) {
    final legacy = RegExp(r'^playlist-backup-v1-(\d+)\.json$').firstMatch(name);
    if (legacy != null) {
      final time = int.tryParse(legacy.group(1)!);
      return time == null ? null : (time: time, number: 1);
    }
    final match = RegExp(r'^栖弦备份-(\d{4})-(\d{2})-(\d{2})(?:-([1-9]\d*))?\.json$').firstMatch(name);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final date = DateTime(year, month, day);
    final number = int.tryParse(match.group(4) ?? '1');
    if (date.year != year || date.month != month || date.day != day || number == null) return null;
    return (time: date.microsecondsSinceEpoch, number: number);
  }

  Future<String> readPlaylistBackup(String name) async {
    final response = await _request(_backupUri(name).toString(), options: Options(method: 'GET', responseType: ResponseType.plain));
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) throw _statusException(status);
    return response.data?.toString() ?? '';
  }

  void close() => _dio.close();
}
