import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pds_saas/auth/controller.dart';
import 'package:pds_saas/auth/demo_repository.dart';
import 'package:pds_saas/auth/models.dart';
import 'package:pds_saas/ui/dashboard_page.dart';
import 'package:pds_saas/work/api.dart';
import 'package:pds_saas/work/importer.dart';

class WorkflowFixture extends WorkApi {
  WorkflowFixture(super.auth);
  bool served = false;
  final records = <Map<String, dynamic>>[
    {
      'id': 'family-1',
      'name': 'Family One',
      'card_number': '000123',
      'mobile': '9999999999',
      'category': 'PHH',
      'family_members': 4,
    },
  ];
  @override
  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path.startsWith('work/overview')) {
      return {
        'total': records.length,
        'distributed': served ? 1 : 0,
        'remaining': served ? 0 : 1,
        'today': served ? 1 : 0,
        'staff': 0,
        'present': 0,
      };
    }
    if (path.startsWith('work/beneficiaries?')) {
      return {
        'rows': served && path.contains('REMAINING') ? [] : records,
        'total': served && path.contains('REMAINING') ? 0 : records.length,
      };
    }
    if (path == 'work/distribute') {
      expect(body!['beneficiaryId'], 'family-1');
      expect(body.containsKey('distributorId'), false);
      served = true;
      return {'ok': true};
    }
    if (path == 'work/staff') return [];
    if (path.startsWith('work/attendance')) return [];
    throw StateError('Unexpected request $method $path');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('Excel text card IDs and integer units import correctly', () {
    final workbook = Excel.createExcel();
    final sheet = workbook.tables.values.first;
    sheet.appendRow(
      [
        'rc',
        'name',
        'mobile',
        'units',
        'category',
      ].map(TextCellValue.new).toList(),
    );
    sheet.appendRow([
      TextCellValue('00042'),
      TextCellValue('Excel family'),
      TextCellValue('9999999999'),
      IntCellValue(3),
      TextCellValue('AAY'),
    ]);
    final imported = parseBeneficiaries(
      'cards.xlsx',
      Uint8List.fromList(workbook.encode()!),
    );
    expect(imported.single['cardNumber'], '00042');
    expect(imported.single['units'], 3);
    expect(imported.single['category'], 'AAY');
  });
  test(
    'CSV preserves leading zeros and rejects invalid category before submission',
    () {
      final rows = parseBeneficiaries(
        'cards.csv',
        Uint8List.fromList(
          utf8.encode(
            'Ration Card Number,Head of Family Name,Mobile Number,Total Units,Category\n0000123,"Family, One",9999999999,4,PHH\n',
          ),
        ),
      );
      expect(rows.single['cardNumber'], '0000123');
      expect(rows.single['name'], 'Family, One');
      expect(
        () => parseBeneficiaries(
          'bad.csv',
          Uint8List.fromList(
            utf8.encode(
              'rc,name,mobile,units,category\n001,Name,9999999999,4,OTHER',
            ),
          ),
        ),
        throwsFormatException,
      );
    },
  );
  for (final width in [320.0, 768.0, 1440.0]) {
    testWidgets(
      'remaining workflow removes distributed family at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = AuthController(DemoAuthRepository());
        await auth.initialize();
        final login = auth.login(
          AccountRole.distributor,
          'distributor1@pds.demo',
          DemoAuthRepository.password,
          false,
        );
        await tester.pump(const Duration(seconds: 2));
        await login;
        final fixture = WorkflowFixture(auth);
        await tester.pumpWidget(
          MaterialApp(
            home: DashboardPage(auth: auth, apiFactory: (_) => fixture),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Total Beneficiaries'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('View remaining families'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('View remaining families'));
        await tester.pumpAndSettle();
        expect(find.text('Family One'), findsOneWidget);
        expect(find.text('Call'), findsOneWidget);
        await tester.ensureVisible(find.text('Distribute / वितरण करें'));
        await tester.tap(find.text('Distribute / वितरण करें'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(fixture.served, true);
        expect(find.text('Family One'), findsNothing);
        expect(find.text('No matching beneficiaries.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
}
