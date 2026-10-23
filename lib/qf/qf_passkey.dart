import 'package:flutter/services.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

class QfPasskeyException implements Exception {
  final String message;

  const QfPasskeyException(this.message);

  @override
  String toString() => message;
}

String qfPasskeyFailureText(Object error) {
  if (error is QfPasskeyException) return error.message;
  if (error is MissingPluginException) {
    return '当前设备不支持通行密钥（系统组件不可用），请改用密码方式。';
  }
  if (error is PlatformException) {
    final code = error.code;
    if (code.contains('NotAllowed') || code.contains('cancel')) {
      return '通行密钥验证已取消。';
    }
    if (code.contains('NotSupported')) {
      return '当前设备不支持通行密钥，请改用密码方式。';
    }
    if (code.contains('InvalidState')) {
      return '该通行密钥已存在或状态异常，请改用其他方式。';
    }
    return '通行密钥验证未完成（$code），请重试或改用密码方式。';
  }
  return '通行密钥验证未完成，请重试或改用密码方式。';
}

class QfPasskeyCeremony {
  static final PasskeyAuthenticator _authenticator = PasskeyAuthenticator();

  static Future<Map<String, dynamic>> register(
    Map<String, dynamic> options,
  ) async {
    try {
      final response = await _authenticator.register(
        RegisterRequestType.fromJson(options),
      );
      return {
        'id': response.id,
        'rawId': response.rawId,
        'type': 'public-key',
        'response': {
          'clientDataJSON': response.clientDataJSON,
          'attestationObject': response.attestationObject,
          'transports': response.transports,
        },
        'clientExtensionResults': <String, dynamic>{},
      };
    } catch (e) {
      throw QfPasskeyException(qfPasskeyFailureText(e));
    }
  }

  static Future<Map<String, dynamic>> authenticate(
    Map<String, dynamic> options,
  ) async {
    try {
      final response = await _authenticator.authenticate(
        AuthenticateRequestType.fromJson(options),
      );
      return {
        'id': response.id,
        'rawId': response.rawId,
        'type': 'public-key',
        'response': {
          'clientDataJSON': response.clientDataJSON,
          'authenticatorData': response.authenticatorData,
          'signature': response.signature,
          'userHandle': response.userHandle,
        },
        'clientExtensionResults': <String, dynamic>{},
      };
    } catch (e) {
      throw QfPasskeyException(qfPasskeyFailureText(e));
    }
  }
}
