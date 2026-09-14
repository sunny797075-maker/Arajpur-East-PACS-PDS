import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:pds_saas/app.dart';
import 'package:pds_saas/auth/controller.dart';
import 'package:pds_saas/auth/demo_repository.dart';
import 'package:pds_saas/auth/models.dart';

Session distributor(String id) => Session(
  userId: id,
  name: id,
  role: AccountRole.distributor,
  distributorId: id,
  accessToken: 'test',
  expiresAt: DateTime.now().add(const Duration(minutes: 5)),
);

class DelayedRepository extends DemoAuthRepository {
  final result = Completer<Session>();
  @override
  Future<Session> login(
    AccountRole role,
    String identifier,
    String password,
    bool remember,
  ) => result.future;
}

void main() {
  test(
    'anonymous and cross-role routes are denied, logout removes access',
    () async {
      final auth = AuthController(DemoAuthRepository());
      await auth.initialize();
      expect(routeGuard(auth, '/super-admin/dashboard'), '/super-admin/login');
      expect(
        await auth.login(
          AccountRole.distributor,
          'distributor1@pds.demo',
          DemoAuthRepository.password,
          false,
        ),
        true,
      );
      expect(routeGuard(auth, '/super-admin/dashboard'), '/unauthorized');
      expect(routeGuard(auth, '/distributor/dashboard'), null);
      await auth.logout();
      expect(routeGuard(auth, '/distributor/dashboard'), '/distributor/login');
      auth.dispose();
    },
  );
  test('tenant scope filters A/B and admin cannot create a business scope', () {
    final a = DistributorScope.fromSession(distributor('DIST-000001'));
    final b = DistributorScope.fromSession(distributor('DIST-000002'));
    final records = [
      {'distributorId': a.id, 'record': 'A'},
      {'distributorId': b.id, 'record': 'B'},
    ];
    expect(a.onlyOwned(records).single['record'], 'A');
    expect(b.onlyOwned(records).single['record'], 'B');
    expect(a.cacheKey('stock'), isNot(b.cacheKey('stock')));
    final admin = Session(
      userId: 'admin',
      name: 'Admin',
      role: AccountRole.superAdmin,
      accessToken: 'test',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
    expect(
      () => DistributorScope.fromSession(admin),
      throwsA(isA<AuthFailure>()),
    );
    expect(
      () => Session(
        userId: 'bad',
        name: 'Bad',
        role: AccountRole.distributor,
        accessToken: 'test',
        expiresAt: DateTime.now(),
      ),
      throwsA(isA<AuthFailure>()),
    );
  });
  test('wrong credentials never establish a session', () async {
    final auth = AuthController(DemoAuthRepository());
    await auth.initialize();
    expect(
      await auth.login(
        AccountRole.superAdmin,
        'distributor1@pds.demo',
        DemoAuthRepository.password,
        false,
      ),
      false,
    );
    expect(auth.session, isNull);
    expect(auth.error, isNotNull);
    auth.dispose();
  });
  test('logout cancels an in-flight login response', () async {
    final repository = DelayedRepository();
    final auth = AuthController(repository);
    await auth.initialize();
    final pending = auth.login(
      AccountRole.distributor,
      'distributor1@pds.demo',
      'anything',
      false,
    );
    await auth.logout();
    repository.result.complete(distributor('DIST-000001'));
    expect(await pending, false);
    expect(auth.session, isNull);
    auth.dispose();
  });
}
