import 'dart:convert';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

List<Map<String, dynamic>> parseBeneficiaries(
  String filename,
  Uint8List bytes,
) {
  if (bytes.length > 5 * 1024 * 1024) {
    throw const FormatException('Choose a file smaller than 5 MB.');
  }
  List<List<String>> rows;
  if (filename.toLowerCase().endsWith('.csv')) {
    final text = utf8.decode(bytes).replaceFirst('\uFEFF', '');
    rows =
        CsvToListConverter(
              shouldParseNumbers: false,
              eol: text.contains('\r\n') ? '\r\n' : '\n',
            )
            .convert(text)
            .map((r) => r.map((v) => v.toString().trim()).toList())
            .toList();
  } else {
    final book = Excel.decodeBytes(bytes);
    if (book.tables.isEmpty) {
      throw const FormatException('Workbook contains no sheets.');
    }
    rows =
        book.tables.values.first.rows
            .map(
              (r) => r.map((v) => v?.value?.toString().trim() ?? '').toList(),
            )
            .toList();
  }
  rows.removeWhere((r) => r.every((v) => v.isEmpty));
  if (rows.length < 2 || rows.length > 501) {
    throw const FormatException(
      'Include a header and 1–500 beneficiaries per import.',
    );
  }
  final headers =
      rows.first
          .map((v) => v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''))
          .toList();
  const aliases = {
    'cardNumber': ['rationcardnumber', 'rcnumber', 'cardnumber', 'rc'],
    'name': ['headoffamilyname', 'headname', 'name'],
    'mobile': ['mobilenumber', 'mobile', 'phone', 'phonenumber'],
    'units': ['totalunits', 'units', 'familymembers'],
    'category': ['category'],
    'address': ['address'],
    'village': ['village'],
  };
  final indexes = <String, int>{};
  for (final field in aliases.entries) {
    indexes[field.key] = headers.indexWhere(field.value.contains);
  }
  for (final field in ['cardNumber', 'name', 'mobile', 'units', 'category']) {
    if (indexes[field] == -1) {
      throw FormatException('Missing required column: $field');
    }
  }
  final result = <Map<String, dynamic>>[];
  for (var i = 1; i < rows.length; i++) {
    String value(String field) {
      final at = indexes[field]!;
      return at < 0 || at >= rows[i].length ? '' : rows[i][at];
    }

    final units = int.tryParse(value('units'));
    final mobile = value('mobile').replaceAll(RegExp(r'[\s()-]'), '');
    if (value('cardNumber').isEmpty ||
        value('name').isEmpty ||
        units == null ||
        units < 1 ||
        units > 100 ||
        !['PHH', 'AAY'].contains(value('category').toUpperCase()) ||
        !RegExp(r'^\+?[1-9]\d{9,14}$').hasMatch(mobile)) {
      throw FormatException(
        'Row ${i + 1}: check card, name, mobile, units (1–100), and PHH/AAY category.',
      );
    }
    result.add({
      'cardNumber': value('cardNumber'),
      'name': value('name'),
      'mobile': mobile,
      'units': units,
      'category': value('category').toUpperCase(),
      'address': value('address'),
      'village': value('village'),
    });
  }
  return result;
}
