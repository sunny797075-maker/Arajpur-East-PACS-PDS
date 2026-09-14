import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

http.Client createClient() => http.Client();
String? csrfToken() => null;

class TokenVault {
  final _storage = const FlutterSecureStorage();
  Future<String?> read() => _storage.read(key: 'pds_saas_refresh');
  Future<void> save(String? token) =>
      token == null
          ? clear()
          : _storage.write(key: 'pds_saas_refresh', value: token);
  Future<void> clear() => _storage.delete(key: 'pds_saas_refresh');
}
