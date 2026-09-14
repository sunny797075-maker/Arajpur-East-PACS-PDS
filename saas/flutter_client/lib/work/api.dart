import 'dart:convert';
import 'package:http/http.dart' as http;
import '../auth/api_repository.dart';
import '../auth/controller.dart';
import '../auth/models.dart';
import '../auth/platform_session.dart';

class WorkApi {
  WorkApi(this.auth, {http.Client? client})
    : _client = client ?? createClient();
  final AuthController auth;
  final http.Client _client;
  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final session = auth.session;
    if (session == null) throw const AuthFailure('Sign in to continue.');
    final repo = auth.repository;
    if (repo is! ApiAuthRepository) {
      throw const AuthFailure('Connect to the live API to use these modules.');
    }
    final request = http.Request(
      method,
      Uri.parse('${repo.baseUrl.replaceAll(RegExp(r'/$'), '')}/$path'),
    );
    request.headers.addAll({
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${session.accessToken}',
    });
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await http.Response.fromStream(
        await _client.send(request),
      ).timeout(const Duration(seconds: 25));
      if (auth.session?.userId != session.userId) {
        throw const AuthFailure('Session changed. Sign in again.');
      }
      final data = jsonDecode(response.body);
      if (response.statusCode >= 400) {
        throw AuthFailure(
          data is Map
              ? (data['error']?.toString() ?? 'Request failed.')
              : 'Request failed.',
        );
      }
      return data;
    } on AuthFailure {
      rethrow;
    } catch (_) {
      throw const AuthFailure(
        'Could not reach the server. Check your connection and retry.',
      );
    }
  }

  void dispose() => _client.close();
}
