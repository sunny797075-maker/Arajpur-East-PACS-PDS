import 'dart:async';
import 'package:flutter/foundation.dart';
import 'models.dart';
import 'repository.dart';

class AuthController extends ChangeNotifier {
  AuthController(this.repository);
  final AuthRepository repository;
  Session? _session;
  Session? get session => _session;
  bool initializing = true, busy = false;
  String? error;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  DistributorScope get distributorScope {
    final current = session;
    if (current == null) throw const AuthFailure('Sign in to continue.');
    return DistributorScope.fromSession(current);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    final generation = ++_generation;
    try {
      final restored = await repository.restore();
      if (generation == _generation && restored != null) _set(restored);
    } catch (_) {
      error = 'Your saved session could not be restored. Please sign in.';
    } finally {
      initializing = false;
      _notify();
    }
  }

  void _set(Session value) {
    if (value.expired) {
      throw const AuthFailure('Session expired. Please sign in.');
    }
    _session = value;
    _timer?.cancel();
    final remaining = value.expiresAt.difference(DateTime.now());
    _timer = Timer(remaining, () => unawaited(renew()));
  }

  Future<bool> login(
    AccountRole role,
    String identifier,
    String password,
    bool remember,
  ) async {
    if (busy) return false;
    busy = true;
    error = null;
    _notify();
    final generation = ++_generation;
    try {
      final value = await repository.login(
        role,
        identifier,
        password,
        remember,
      );
      if (generation != _generation || _disposed) return false;
      if (value.role != role) {
        throw const AuthFailure(
          'This account cannot access the selected login.',
        );
      }
      _set(value);
      return true;
    } catch (e) {
      error =
          e is AuthFailure ? e.message : 'Unable to sign in. Please try again.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> renew() async {
    final old = session;
    if (old == null || busy) return;
    final generation = ++_generation;
    // Do not expose protected content while an expired session is refreshed.
    _session = null;
    initializing = true;
    _notify();
    try {
      final next = await repository.refresh(old);
      if (next.userId != old.userId ||
          next.role != old.role ||
          next.distributorId != old.distributorId) {
        throw const AuthFailure(
          'Session identity changed. Please sign in again.',
        );
      }
      if (generation == _generation && !_disposed) _set(next);
    } catch (_) {
      error = 'Your session ended. Please sign in again.';
    } finally {
      initializing = false;
      _notify();
    }
  }

  Future<void> logout() async {
    final previous = session;
    ++_generation;
    _timer?.cancel();
    _session = null;
    error = null;
    initializing = false;
    busy = true;
    _notify();
    try {
      if (previous != null) {
        await repository.logout(previous);
      } else {
        await repository.forgetLocalSession();
      }
    } catch (_) {
      error =
          'Signed out here. Server revocation could not be confirmed; reconnect before signing in again.';
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    repository.dispose();
    super.dispose();
  }
}
