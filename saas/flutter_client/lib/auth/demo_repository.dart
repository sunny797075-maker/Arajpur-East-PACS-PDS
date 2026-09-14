import 'models.dart';
import 'repository.dart';

/// Explicit development fixture. Never used unless PDS_DEMO=true at build time.
/// No persistent credentials or business data, and no network requests.
class DemoAuthRepository implements AuthRepository {
  static const password = 'Preview@12345';
  @override
  bool get isDemo => true;
  @override
  Future<Session> login(
    AccountRole role,
    String identifier,
    String secret,
    bool remember,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final id = identifier.trim().toLowerCase();
    final first = [
      'distributor1@pds.demo',
      '9876543210',
      '+919876543210',
    ].contains(id);
    final valid =
        role == AccountRole.superAdmin
            ? id == 'admin@pds.demo' || id == 'admin-001'
            : first ||
                [
                  'distributor2@pds.demo',
                  '9876543211',
                  '+919876543211',
                ].contains(id);
    if (!valid || secret != password) {
      throw const AuthFailure('Incorrect ID or password. Please try again.');
    }
    return Session(
      userId:
          role == AccountRole.superAdmin
              ? 'demo-admin'
              : first
              ? 'DIST-000001'
              : 'DIST-000002',
      name:
          role == AccountRole.superAdmin
              ? 'Platform administrator'
              : first
              ? 'Arajpur East PACS'
              : 'Sample distributor B',
      role: role,
      distributorId:
          role == AccountRole.distributor
              ? (first ? 'DIST-000001' : 'DIST-000002')
              : null,
      accessToken: 'demo-session',
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }

  @override
  Future<Session?> restore() async => null;
  @override
  Future<Session> refresh(Session session) async =>
      throw const AuthFailure('Preview session ended. Sign in again.');
  @override
  Future<void> logout(Session session) async {}
  @override
  Future<void> forgetLocalSession() async {}
  @override
  Future<void> forgotPassword(AccountRole role, String identifier) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  void dispose() {}
  @override
  Future<String> registerDistributor(Map<String, Object?> fields) async =>
      throw const AuthFailure(
        'Account registration requires the live service. Demo accounts are shown on the sign-in screen.',
      );
}
