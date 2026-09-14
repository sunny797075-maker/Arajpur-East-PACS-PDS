// Only the CSRF cookie is readable. Refresh cookies must be HttpOnly.
import 'package:web/web.dart' as web;
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

http.Client createClient() => BrowserClient()..withCredentials = true;
String? csrfToken() {
  for (final part in web.document.cookie.split(';')) {
    final item = part.trim();
    if (item.startsWith('pds_csrf=')) {
      return Uri.decodeComponent(item.substring(9));
    }
  }
  return null;
}

class TokenVault {
  Future<String?> read() async => null;
  Future<void> save(String? token) async {}
  Future<void> clear() async {}
}
