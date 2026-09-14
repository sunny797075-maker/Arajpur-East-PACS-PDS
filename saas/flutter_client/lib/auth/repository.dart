import 'models.dart';

abstract class AuthRepository {
  bool get isDemo;
  Future<Session> login(
    AccountRole role,
    String identifier,
    String password,
    bool remember,
  );
  Future<Session?> restore();
  Future<Session> refresh(Session session);
  Future<void> logout(Session session);
  Future<void> forgetLocalSession();
  Future<void> forgotPassword(AccountRole role, String identifier);
  Future<String> registerDistributor(Map<String, Object?> fields);
  void dispose();
}
