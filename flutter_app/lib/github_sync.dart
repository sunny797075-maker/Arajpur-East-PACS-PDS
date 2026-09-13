import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class SyncFailure implements Exception {
  final String message;
  final bool retryable;
  const SyncFailure(this.message, {this.retryable = false});
  @override
  String toString() => message;
}

class RemoteRegister {
  final Register register;
  final String? sha;
  final String branch;
  const RemoteRegister(this.register, this.sha, this.branch);
}

class GitHubSync {
  static const repository = 'sunny797075-maker/Arajpur-East-PACS-PDS';
  final http.Client client;
  GitHubSync(this.client);
  Map<String, String> headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Arajpur-East-PACS-PDS',
    'Content-Type': 'application/json',
  };
  Future<http.Response> request(
    String method,
    String path,
    String token, {
    Json? body,
  }) async {
    final uri = Uri.https('api.github.com', '/repos/$repository$path');
    return (method == 'PUT'
            ? client.put(uri, headers: headers(token), body: jsonEncode(body))
            : client.get(uri, headers: headers(token)))
        .timeout(const Duration(seconds: 25));
  }

  Never fail(http.Response response) {
    if (response.statusCode == 401) {
      throw const SyncFailure(
        'GitHub token is invalid or expired. Update it in Settings.',
      );
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      final limited =
          response.statusCode == 429 ||
          response.headers['x-ratelimit-remaining'] == '0' ||
          response.headers.containsKey('retry-after');
      throw SyncFailure(
        limited
            ? 'GitHub rate limit reached. Sync will retry later.'
            : 'GitHub denied access. Check Contents read/write permission and branch rules.',
        retryable: limited,
      );
    }
    if (response.statusCode == 404) {
      throw const SyncFailure(
        'Repository is inaccessible. Check the token has access to the configured repository.',
      );
    }
    throw SyncFailure(
      'GitHub returned HTTP ${response.statusCode}. Local transactions are retained.',
      retryable: response.statusCode >= 500 || response.statusCode == 408,
    );
  }

  Future<RemoteRegister> fetch(String token) async {
    final metadata = await request('GET', '', token);
    if (metadata.statusCode != 200) fail(metadata);
    final repo = jsonDecode(metadata.body) as Map;
    // This file contains phone numbers and ration-card identities.
    if (repo['private'] != true) {
      throw const SyncFailure(
        'Sync requires a private repository because data.json contains ration-card and phone details. Make this repository private, then retry.',
      );
    }
    final branch = repo['default_branch'] as String;
    final response = await client
        .get(
          Uri.https('api.github.com', '/repos/$repository/contents/data.json', {
            'ref': branch,
          }),
          headers: headers(token),
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode == 404) {
      return RemoteRegister(Register.empty(), null, branch);
    }
    if (response.statusCode != 200) fail(response);
    final body = jsonDecode(response.body) as Map;
    if (body['type'] != 'file' ||
        body['encoding'] != 'base64' ||
        body['content'] is! String ||
        (body['size'] as num) > 900000) {
      throw const SyncFailure(
        'data.json must be a valid PDS JSON file smaller than 900 KB. Remote data was not changed.',
      );
    }
    final raw = utf8.decode(
      base64Decode((body['content'] as String).replaceAll(RegExp(r'\s'), '')),
    );
    try {
      return RemoteRegister(
        Register.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)),
        body['sha'] as String,
        branch,
      );
    } catch (_) {
      throw const SyncFailure(
        'Remote data.json is not a valid PDS register. It was not overwritten.',
      );
    }
  }

  Future<Register> mergeAndPush(
    String token,
    List<Json> operations, {
    Register? baseline,
  }) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final remote = await fetch(token);
      if (baseline != null) {
        final queuedPeople =
            operations
                .where((op) => op['type'] == 'add')
                .map((op) => (op['household'] as Map)['id'])
                .toSet();
        final queuedSales =
            operations
                .where((op) => op['type'] == 'sale')
                .map((op) => (op['sale'] as Map)['id'])
                .toSet();
        final remotePeople =
            remote.register.households.map((p) => p.id).toSet();
        final remoteSales = remote.register.sales.map((s) => s.id).toSet();
        if (baseline.households.any(
              (p) =>
                  !queuedPeople.contains(p.id) && !remotePeople.contains(p.id),
            ) ||
            baseline.sales.any(
              (s) => !queuedSales.contains(s.id) && !remoteSales.contains(s.id),
            )) {
          throw const SyncFailure(
            'Previously synced records are missing from GitHub. Local history is retained. Restore or reconcile data.json before retrying.',
          );
        }
      }
      for (final operation in operations) {
        remote.register.apply(operation);
      }
      if (operations.isEmpty) return remote.register;
      final bytes = utf8.encode(jsonEncode(remote.register.toJson()));
      if (bytes.length > 900000) {
        throw const SyncFailure(
          'The register exceeds the 900 KB sync limit. Export and archive data before continuing sync.',
        );
      }
      final response = await request(
        'PUT',
        '/contents/data.json',
        token,
        body: {
          'message':
              'Update PDS register (${operations.length} offline operations)',
          'content': base64Encode(bytes),
          'branch': remote.branch,
          if (remote.sha != null) 'sha': remote.sha,
        },
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        return remote.register;
      }
      if (response.statusCode == 409 || response.statusCode == 422) continue;
      fail(response);
    }
    throw const SyncFailure(
      'The repository changed during sync or rejected the commit. Changes remain queued; check branch rules and retry.',
      retryable: true,
    );
  }
}
