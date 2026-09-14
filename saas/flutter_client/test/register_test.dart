import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pds_saas/app.dart';
import 'package:pds_saas/auth/controller.dart';
import 'package:pds_saas/auth/demo_repository.dart';

class SignupPreview extends DemoAuthRepository {
  Map<String, Object?>? submitted;
  @override
  Future<String> registerDistributor(Map<String, Object?> fields) async {
    submitted = fields;
    return 'DIST-000099';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [320.0, 768.0, 1440.0]) {
    testWidgets(
      'registration issues ID and pre-fills sign-in at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = SignupPreview();
        final auth = AuthController(repo);
        await auth.initialize();
        await tester.pumpWidget(PdsApp(auth: auth));
        await tester.pumpAndSettle();
        final register = find.text('New distributor? Create an account');
        await tester.ensureVisible(register);
        await tester.tap(register);
        await tester.pumpAndSettle();
        final fields = {
          'organizationName': 'My PDS Shop',
          'ownerName': 'Owner',
          'email': 'owner@example.org',
          'mobile': '9876543210',
          'panchayat': 'Ward 1',
          'village': 'Locality',
          'address': 'Street 1',
          'pinCode': '853204',
          'password': 'my secure password',
          'confirmPassword': 'my secure password',
        };
        for (final entry in fields.entries) {
          final finder = find.byKey(ValueKey(entry.key));
          await tester.ensureVisible(finder);
          await tester.enterText(finder, entry.value);
        }
        final submit = find.text('Create account & get Distributor ID');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(find.text('Your account is ready'), findsOneWidget);
        expect(find.text('DIST-000099'), findsOneWidget);
        expect(repo.submitted!['mobile'], '+919876543210');
        final organization =
            repo.submitted!['organization'] as Map<String, Object?>;
        expect(organization['state'], 'Bihar');
        expect(organization['district'], 'Madhepura');
        expect(organization['block'], 'Chausa');
        expect(repo.submitted!.containsKey('role'), false);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Continue to sign in'));
        await tester.tap(find.text('Continue to sign in'));
        await tester.pumpAndSettle();
        expect(find.text('Distributor Login'), findsOneWidget);
        expect(find.text('owner@example.org'), findsOneWidget);
        expect(find.text('Super Admin sign in'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
}
