import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'repository.dart';
import 'platform_session.dart';

class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository(this.baseUrl, {http.Client? client})
    : _client = client ?? createClient();
  final String baseUrl;
  final http.Client _client;
  final _vault = TokenVault();
  String? _refreshToken;
  bool _remember = false;
  int _generation = 0;
  Future<void> _storageTail = Future<void>.value();
  Future<void> _persist(Future<void> Function() operation) {
    final next = _storageTail.then((_) => operation());
    _storageTail = next.catchError((Object _) {});
    return next;
  }

  @override
  bool get isDemo => false;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body, {
    String? access,
  }) async {
    final endpoint = apiEndpoint(path);
    if (endpoint == null) {
      throw const AuthFailure(
        'Authentication API is not configured. Set PDS_API_URL to your HTTPS API.',
      );
    }
    try {
      final csrf = csrfToken();
      final response = await _client
          .post(
            endpoint,
            headers: {
              'Content-Type': 'application/json',
              if (access != null) 'Authorization': 'Bearer $access',
              if (csrf != null) 'X-CSRF-Token': csrf,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 401) {
        throw const AuthFailure(
          'Your credentials or session are invalid. Please sign in.',
        );
      }
      if (response.statusCode == 403) {
        throw const AuthFailure(
          'Access is unavailable. Your account may be suspended or awaiting approval.',
        );
      }
      if (response.statusCode == 429) {
        throw const AuthFailure(
          'Too many attempts. Please wait before trying again.',
        );
      }
      if (response.statusCode == 409) {
        throw const AuthFailure(
          'An account already uses this email or mobile. Use your existing account, or retry registration with its original password to retrieve the ID.',
        );
      }
      if (response.statusCode == 400) {
        throw const AuthFailure(
          'Please check your registration fields. Passwords must match and contain at least 12 characters.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const AuthFailure(
          'The authentication service is unavailable. Please try again.',
        );
      }
      return response.body.isEmpty
          ? {}
          : jsonDecode(response.body) as Map<String, dynamic>;
    } on AuthFailure {
      rethrow;
    } on TimeoutException {
      throw const AuthFailure(
        'Connection timed out. Check your internet connection.',
      );
    } on http.ClientException {
      throw const AuthFailure(
        'Cannot connect. Check your internet connection and try again.',
      );
    } catch (_) {
      throw const AuthFailure('The server returned an unexpected response.');
    }
  }

  Uri? apiEndpoint(String path) {
    final cleanBase = baseUrl.trim().replaceAll(RegExp(r'/$'), '');
    if (cleanBase.isEmpty) return null;
    final base = Uri.tryParse(cleanBase);
    if (base == null) return null;
    if (!base.hasAuthority && cleanBase.startsWith('/')) {
      return Uri.parse('$cleanBase/$path');
    }
    if (!base.hasAuthority ||
        (base.scheme != 'https' &&
            !(base.scheme == 'http' &&
                ['localhost', '127.0.0.1', '10.0.2.2'].contains(base.host)))) {
      return null;
    }
    return Uri.parse('$cleanBase/$path');
  }

  Future<Session> _accept(
    Map<String, dynamic> data, {
    AccountRole? expected,
    Session? previous,
    required int generation,
  }) async {
    final session = Session.fromJson(data);
    if (session.expired || (expected != null && session.role != expected)) {
      throw const AuthFailure('This account cannot access the selected login.');
    }
    if (previous != null &&
        (session.userId != previous.userId ||
            session.distributorId != previous.distributorId)) {
      throw const AuthFailure(
        'Session identity changed. Please sign in again.',
      );
    }
    if (!kIsWeb && (session.refreshToken?.isNotEmpty != true)) {
      throw const AuthFailure(
        'The server did not return a native session token.',
      );
    }
    await _persist(() async {
      if (generation != _generation) {
        throw const AuthFailure('Sign-in was cancelled.');
      }
      _refreshToken = session.refreshToken;
      await _vault.save(_remember ? _refreshToken : null);
      await (await SharedPreferences.getInstance()).setBool(
        'pds_saas_remember',
        _remember,
      );
    });
    if (generation != _generation) {
      throw const AuthFailure('Sign-in was cancelled.');
    }
    return session;
  }

  @override
  Future<Session> login(
    AccountRole role,
    String identifier,
    String password,
    bool remember,
  ) async {
    final generation = ++_generation;
    _remember = remember;
    final response = await _post('auth/${role.path}/login', {
      'identifier': identifier,
      'password': password,
      'rememberMe': remember,
      'clientType': kIsWeb ? 'WEB' : 'NATIVE',
    });
    return _accept(response, expected: role, generation: generation);
  }

  @override
  Future<Session?> restore() async {
    final generation = ++_generation;
    _remember =
        (await SharedPreferences.getInstance()).getBool('pds_saas_remember') ??
        false;
    if (!_remember) return null;
    _refreshToken = await _vault.read();
    if (!kIsWeb && _refreshToken == null) return null;
    return _accept(
      await _post('auth/refresh', {if (!kIsWeb) 'refreshToken': _refreshToken}),
      generation: generation,
    );
  }

  @override
  Future<Session> refresh(Session session) async {
    final generation = ++_generation;
    return _accept(
      await _post('auth/refresh', {if (!kIsWeb) 'refreshToken': _refreshToken}),
      expected: session.role,
      previous: session,
      generation: generation,
    );
  }

  @override
  Future<void> logout(Session session) async {
    await forgetLocalSession();
    await _post('auth/logout', {}, access: session.accessToken);
  }

  @override
  Future<void> forgetLocalSession() async {
    ++_generation;
    _refreshToken = null;
    await _persist(() async {
      await _vault.clear();
      await (await SharedPreferences.getInstance()).remove('pds_saas_remember');
    });
  }

  @override
  Future<void> forgotPassword(AccountRole role, String identifier) async {
    await _post('auth/${role.path}/forgot-password', {
      'identifier': identifier,
    });
  }

  @override
  void dispose() => _client.close();
  @override
  Future<String> registerDistributor(Map<String, Object?> fields) async {
    final result = await _post('auth/distributor/register', fields);
    final id = result['distributorId'];
    if (id is! String || !RegExp(r'^DIST-\d+$').hasMatch(id)) {
      throw const AuthFailure(
        'The server did not return a valid Distributor ID. Retry with the same details.',
      );
    }
    return id;
  }
}
