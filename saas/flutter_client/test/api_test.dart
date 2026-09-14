import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pds_saas/auth/api_repository.dart';
import 'package:pds_saas/auth/models.dart';

void main() {
  test(
    'API sends distributor credentials only to the distributor endpoint',
    () async {
      final repository = ApiAuthRepository(
        'https://pds.example/api/v1',
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/auth/distributor/login');
          final body = jsonDecode(request.body);
          expect(body['identifier'], 'owner@example.org');
          expect(body['rememberMe'], true);
          expect(body.containsKey('role'), false);
          expect(body.containsKey('distributorId'), false);
          return http.Response('{}', 401);
        }),
      );
      await expectLater(
        repository.login(
          AccountRole.distributor,
          'owner@example.org',
          'secret',
          true,
        ),
        throwsA(isA<AuthFailure>()),
      );
      repository.dispose();
    },
  );
  test(
    'production API rejects public HTTP before transmitting credentials',
    () async {
      final repository = ApiAuthRepository(
        'http://15.252.37.89/api/v1',
        client: MockClient((_) async {
          fail('Credentials must not be sent over public HTTP');
        }),
      );
      await expectLater(
        repository.login(AccountRole.superAdmin, 'admin', 'secret', false),
        throwsA(isA<AuthFailure>()),
      );
      repository.dispose();
    },
  );
  test('server role cannot be elevated through selected login page', () async {
    final repository = ApiAuthRepository(
      'https://pds.example/api/v1',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'userId': 'other',
            'name': 'Other',
            'role': 'DISTRIBUTOR',
            'distributorId': 'DIST-000002',
            'accessToken': 'test',
            'expiresAt':
                DateTime.now()
                    .add(const Duration(minutes: 5))
                    .toIso8601String(),
          }),
          200,
        ),
      ),
    );
    await expectLater(
      repository.login(AccountRole.superAdmin, 'admin', 'secret', false),
      throwsA(isA<AuthFailure>()),
    );
    repository.dispose();
  });
}
