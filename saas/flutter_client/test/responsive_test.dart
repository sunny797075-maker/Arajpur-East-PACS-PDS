import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pds_saas/app.dart';
import 'package:pds_saas/auth/controller.dart';
import 'package:pds_saas/auth/demo_repository.dart';
import 'package:pds_saas/auth/models.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final size in [
    const Size(320, 740),
    const Size(768, 1024),
    const Size(1440, 1000),
  ]) {
    for (final role in AccountRole.values) {
      testWidgets('${role.label} login and dashboard fit ${size.width}', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = AuthController(DemoAuthRepository());
        await auth.initialize();
        await tester.pumpWidget(
          PdsApp(auth: auth, initialLocation: role.login),
        );
        await tester.pumpAndSettle();
        expect(find.text('${role.label} Login'), findsOneWidget);
        expect(find.text('Powered by MENHI GLOBAL TECH'), findsOneWidget);
        expect(find.text('Super Admin sign in'), findsNothing);
        expect(find.textContaining('8757114064'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byType(TextFormField).at(0),
          role == AccountRole.superAdmin
              ? 'ADMIN-001'
              : 'distributor1@pds.demo',
        );
        await tester.enterText(
          find.byType(TextFormField).at(1),
          DemoAuthRepository.password,
        );
        await tester.ensureVisible(find.text('Sign in'));
        await tester.tap(find.text('Sign in'));
        await tester.pumpAndSettle();
        expect(auth.session?.role, role);
        expect(
          find.text(
            role == AccountRole.superAdmin
                ? 'Super Admin workspace'
                : 'Distributor workspace',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Sign out'));
        await tester.pumpAndSettle();
        expect(auth.session, isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      });
    }
  }
  testWidgets('distributor ID is rejected and mobile number signs in', (
    tester,
  ) async {
    final auth = AuthController(DemoAuthRepository());
    await auth.initialize();
    await tester.pumpWidget(PdsApp(auth: auth));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'DIST-000001');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      DemoAuthRepository.password,
    );
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter your registered email or mobile number.'),
      findsOneWidget,
    );
    expect(auth.session, isNull);
    await tester.enterText(find.byType(TextFormField).first, '9876543210');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(auth.session?.distributorId, 'DIST-000001');
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets('mobile validation, password visibility and recovery work', (
    tester,
  ) async {
    final auth = AuthController(DemoAuthRepository());
    await auth.initialize();
    await tester.pumpWidget(PdsApp(auth: auth));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your Email or Mobile Number.'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Show password'));
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'distributor1@pds.demo',
    );
    await tester.ensureVisible(find.text('Send recovery instructions'));
    await tester.tap(find.text('Send recovery instructions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no email was sent'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
