import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

class QfPasskeyCeremony {
  static final PasskeyAuthenticator _authenticator = PasskeyAuthenticator();

  static Future<Map<String, dynamic>> register(
    Map<String, dynamic> options,
  ) async {
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
  }

  static Future<Map<String, dynamic>> authenticate(
    Map<String, dynamic> options,
  ) async {
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
  }
}
