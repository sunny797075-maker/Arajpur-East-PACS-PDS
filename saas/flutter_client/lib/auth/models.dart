enum AccountRole {
  superAdmin('super-admin', 'Super Admin'),
  distributor('distributor', 'Distributor');

  const AccountRole(this.path, this.label);
  final String path;
  final String label;
  String get home => '/$path/dashboard';
  String get login => '/$path/login';
}

class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class Session {
  Session({
    required this.userId,
    required this.name,
    required this.role,
    required this.accessToken,
    required this.expiresAt,
    this.distributorId,
    this.refreshToken,
    this.profile,
  }) {
    if (userId.isEmpty ||
        accessToken.isEmpty ||
        (role == AccountRole.distributor &&
            !RegExp(r'^DIST-\d+$').hasMatch(distributorId ?? '')) ||
        (role == AccountRole.superAdmin &&
            (distributorId != null || profile != null)) ||
        (profile != null && profile!.distributorId != distributorId)) {
      throw const AuthFailure(
        'The server returned an invalid account session.',
      );
    }
  }
  final String userId, name, accessToken;
  final AccountRole role;
  final String? distributorId, refreshToken;
  final DateTime expiresAt;
  final DistributorProfile? profile;
  bool get expired => !expiresAt.isAfter(DateTime.now());
  factory Session.fromJson(Map<String, dynamic> data) {
    final role = switch (data['role']) {
      'SUPER_ADMIN' => AccountRole.superAdmin,
      'DISTRIBUTOR' => AccountRole.distributor,
      _ => throw const AuthFailure('This account type is not supported.'),
    };
    return Session(
      userId: data['userId'] as String,
      name: data['name'] as String,
      role: role,
      accessToken: data['accessToken'] as String,
      distributorId: data['distributorId'] as String?,
      refreshToken: data['refreshToken'] as String?,
      expiresAt: DateTime.parse(data['expiresAt'] as String).toUtc(),
      profile:
          data['profile'] == null
              ? null
              : DistributorProfile.fromJson(
                data['profile'] as Map<String, dynamic>,
              ),
    );
  }
}

class DistributorProfile {
  const DistributorProfile({
    required this.distributorId,
    required this.organizationName,
    required this.address,
    required this.phone,
  });
  final String distributorId, organizationName, address, phone;
  factory DistributorProfile.fromJson(Map<String, dynamic> value) =>
      DistributorProfile(
        distributorId: value['distributorId'] as String,
        organizationName: value['organizationName'] as String,
        address: value['address'] as String? ?? '',
        phone: value['phone'] as String? ?? '',
      );
  String get contactText => [
    organizationName,
    address,
    phone,
  ].where((value) => value.trim().isNotEmpty).join('\n');
}

/// No caller-supplied tenant selection. Later repositories receive this scope
/// from the current authenticated session, and the server must verify it too.
class DistributorScope {
  DistributorScope.fromSession(Session session)
    : id = session.distributorId ?? '' {
    if (session.role != AccountRole.distributor ||
        id.isEmpty ||
        session.expired) {
      throw const AuthFailure('A current distributor session is required.');
    }
  }
  final String id;
  String cacheKey(String resource) => '$id:$resource';
  List<Map<String, Object?>> onlyOwned(
    Iterable<Map<String, Object?>> records,
  ) => records
      .where((record) => record['distributorId'] == id)
      .toList(growable: false);
}
