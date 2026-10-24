import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'qf_config.dart';
import 'qf_http_client.dart';
import 'qf_providers.dart';

class QfGoogleAuthException implements Exception {
  final String message;

  const QfGoogleAuthException(this.message);

  @override
  String toString() => message;
}

class QfGoogleAuth {
  static bool _androidInitialized = false;

  static bool get isConfigured {
    if (Platform.isAndroid) return QfRuntime.googleWebClientId.isNotEmpty;
    if (Platform.isWindows) return QfRuntime.googleClientId.isNotEmpty;
    return false;
  }

  static Future<String> fetchIdToken() async {
    if (Platform.isAndroid) return _androidIdToken();
    if (Platform.isWindows) return _windowsIdToken();
    throw const QfGoogleAuthException('当前平台暂不支持谷歌登录。');
  }

  static Future<String> _androidIdToken() async {
    final serverClientId = QfRuntime.googleWebClientId;
    if (serverClientId.isEmpty) {
      throw const QfGoogleAuthException('谷歌登录尚未完成配置，请改用邮箱或账户 ID 登录。');
    }
    final signIn = GoogleSignIn.instance;
    if (!_androidInitialized) {
      await signIn.initialize(serverClientId: serverClientId);
      _androidInitialized = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await signIn.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const QfGoogleAuthException('已取消谷歌登录。');
      }
      throw const QfGoogleAuthException('谷歌登录失败，请重试或改用密码登录。');
    }
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const QfGoogleAuthException('谷歌登录失败：未取得登录凭证，请重试。');
    }
    return idToken;
  }

  // Google's desktop flow takes no client secret when PKCE is used: the
  // token endpoint lists client_secret as optional for installed apps.
  static Future<String> _windowsIdToken() async {
    final clientId = QfRuntime.googleClientId;
    if (clientId.isEmpty) {
      throw const QfGoogleAuthException('谷歌登录尚未完成配置，请改用邮箱或账户 ID 登录。');
    }
    final verifier = _randomToken(32);
    final challenge = _base64Url(sha256.convert(utf8.encode(verifier)).bytes);
    final state = _randomToken(24);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirectUri = 'http://127.0.0.1:${server.port}';
      final authUri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': 'openid email profile',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'prompt': 'select_account',
      });
      final launched = await launchUrl(
        authUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw const QfGoogleAuthException('无法打开系统浏览器，请检查默认浏览器设置后重试。');
      }
      final params = await _awaitCallback(server);
      if (params['state'] != state) {
        throw const QfGoogleAuthException('谷歌登录失败：授权响应校验未通过，请重试。');
      }
      final error = params['error'];
      if (error != null && error.isNotEmpty) {
        if (error == 'access_denied') {
          throw const QfGoogleAuthException('已取消谷歌授权。');
        }
        throw const QfGoogleAuthException('谷歌登录失败，请重试或改用密码登录。');
      }
      final code = params['code'];
      if (code == null || code.isEmpty) {
        throw const QfGoogleAuthException('谷歌登录失败：未取得授权码，请重试。');
      }
      return await _exchangeCode(
        code: code,
        verifier: verifier,
        redirectUri: redirectUri,
        clientId: clientId,
      );
    } finally {
      await server.close(force: true);
    }
  }

  static Future<Map<String, String>> _awaitCallback(HttpServer server) async {
    final completer = Completer<Map<String, String>>();
    final subscription = server.listen((request) async {
      final params = request.uri.queryParameters;
      final isResult =
          params.containsKey('code') || params.containsKey('error');
      if (isResult) {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_callbackPage);
        if (!completer.isCompleted) completer.complete(params);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    try {
      return await completer.future.timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw const QfGoogleAuthException('谷歌登录等待超时，请重试。');
    } finally {
      await subscription.cancel();
    }
  }

  static Future<String> _exchangeCode({
    required String code,
    required String verifier,
    required String redirectUri,
    required String clientId,
  }) async {
    final client = await QfHttpClient.create(
      uri: Uri.parse('https://oauth2.googleapis.com/token'),
    );
    try {
      final request = await client.postUrl(
        Uri.parse('https://oauth2.googleapis.com/token'),
      );
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(
        Uri(
          queryParameters: {
            'code': code,
            'client_id': clientId,
            'code_verifier': verifier,
            'grant_type': 'authorization_code',
            'redirect_uri': redirectUri,
          },
        ).query,
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await response.transform(utf8.decoder).join();
      Map<String, dynamic> data = {};
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) data = Map<String, dynamic>.from(decoded);
      } catch (_) {
        data = {};
      }
      final idToken = (data['id_token'] ?? '').toString();
      if (response.statusCode == 200 && idToken.isNotEmpty) return idToken;
      throw const QfGoogleAuthException('谷歌登录失败，请重试或改用密码登录。');
    } on QfGoogleAuthException {
      rethrow;
    } catch (_) {
      throw const QfGoogleAuthException(QfCopy.networkAccountUnreachable);
    } finally {
      client.close(force: true);
    }
  }

  static String _randomToken(int byteCount) {
    final random = Random.secure();
    return _base64Url(
      List<int>.generate(byteCount, (_) => random.nextInt(256)),
    );
  }

  static String _base64Url(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static const String _callbackPage =
      '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
      '<title>QFClash</title></head><body>'
      '<p>授权已完成，请关闭此页面并返回 QFClash。</p>'
      '</body></html>';
}
