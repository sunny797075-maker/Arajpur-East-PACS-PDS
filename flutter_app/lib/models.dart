import 'dart:convert';
import 'dart:math';

typedef Json = Map<String, dynamic>;

String monthKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
String adjacentMonth(String month, int offset) {
  final parts = month.split('-').map(int.parse).toList();
  return monthKey(DateTime(parts[0], parts[1] + offset));
}

String monthLabel(String key) {
  const names = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final parts = key.split('-');
  return '${names[int.parse(parts[1]) - 1]} ${parts[0]}';
}

String newId() =>
    List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
bool validMonth(dynamic key) =>
    key is String && RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(key);
String quantity(num value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
Never invalid(String message) => throw FormatException(message);
String requiredText(Json data, String key, int max) {
  final value = data[key];
  if (value is! String || value.trim().isEmpty || value.length > max) {
    invalid('Invalid $key.');
  }
  return value.trim();
}

double grain(dynamic value) {
  if (value is! num ||
      !value.isFinite ||
      value < 0 ||
      value > 10000 ||
      (value * 100 - (value * 100).round()).abs() > 0.00001) {
    invalid('Invalid grain quota.');
  }
  return value.toDouble();
}

class Household {
  final String id, rcNumber, headName, phone;
  final int members;
  final double wheat, rice;
  const Household({
    required this.id,
    required this.rcNumber,
    required this.headName,
    required this.phone,
    required this.members,
    required this.wheat,
    required this.rice,
  });
  factory Household.fromJson(Json data) {
    final phone = requiredText(
      data,
      'phone',
      20,
    ).replaceAll(RegExp(r'[\s()-]'), '');
    if (!RegExp(r'^\+?\d{7,15}$').hasMatch(phone)) {
      invalid('Phone must contain 7–15 digits.');
    }
    final members = data['members'];
    if (members is! int || members < 1 || members > 100) {
      invalid('Family members must be 1–100.');
    }
    final wheat = grain(data['wheat']), rice = grain(data['rice']);
    if (wheat + rice <= 0) {
      invalid('At least one quota must be greater than zero.');
    }
    return Household(
      id: requiredText(data, 'id', 160),
      rcNumber: requiredText(data, 'rcNumber', 40),
      headName: requiredText(data, 'headName', 100),
      phone: phone,
      members: members,
      wheat: wheat,
      rice: rice,
    );
  }
  Json toJson() => {
    'id': id,
    'rcNumber': rcNumber,
    'headName': headName,
    'phone': phone,
    'members': members,
    'wheat': wheat,
    'rice': rice,
  };
}

class Sale {
  final String id, beneficiaryId, month, rcNumber, headName, recordedAt;
  final double wheat, rice;
  const Sale({
    required this.id,
    required this.beneficiaryId,
    required this.month,
    required this.rcNumber,
    required this.headName,
    required this.recordedAt,
    required this.wheat,
    required this.rice,
  });
  factory Sale.fromJson(Json data) {
    if (!validMonth(data['month'])) invalid('Invalid sale month.');
    final recordedAt = requiredText(data, 'recordedAt', 60);
    if (DateTime.tryParse(recordedAt) == null) invalid('Invalid sale date.');
    final wheat = grain(data['wheat']), rice = grain(data['rice']);
    if (wheat + rice <= 0) invalid('Invalid sale amount.');
    return Sale(
      id: requiredText(data, 'id', 160),
      beneficiaryId: requiredText(data, 'beneficiaryId', 160),
      month: data['month'],
      rcNumber: requiredText(data, 'rcNumber', 40),
      headName: requiredText(data, 'headName', 100),
      recordedAt: recordedAt,
      wheat: wheat,
      rice: rice,
    );
  }
  Json toJson() => {
    'id': id,
    'beneficiaryId': beneficiaryId,
    'month': month,
    'rcNumber': rcNumber,
    'headName': headName,
    'recordedAt': recordedAt,
    'wheat': wheat,
    'rice': rice,
  };
}

class Register {
  final List<String> months;
  final List<Household> households;
  final List<Sale> sales;
  final Map<String, Sale> _saleIndex;
  Register({
    required this.months,
    required this.households,
    required this.sales,
  }) : _saleIndex = {
         for (final sale in sales) '${sale.beneficiaryId}:${sale.month}': sale,
       };
  factory Register.empty() {
    final now = monthKey(DateTime.now());
    return Register(
      months: [adjacentMonth(now, -1), now],
      households: [],
      sales: [],
    );
  }
  factory Register.fromJson(Json data) {
    if (![1, 2].contains(data['version']) ||
        !validMonth(data['activeMonth']) ||
        data['beneficiaries'] is! List ||
        data['sales'] is! List) {
      invalid('Unsupported PDS data file.');
    }
    final households =
        (data['beneficiaries'] as List)
            .map((p) => Household.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList();
    final sales =
        (data['sales'] as List)
            .map((s) => Sale.fromJson(Map<String, dynamic>.from(s as Map)))
            .toList();
    final List<String> months;
    if (data['version'] == 1) {
      months =
          {
              data['activeMonth'] as String,
              adjacentMonth(data['activeMonth'], -1),
              ...sales.map((s) => s.month),
            }.toList()
            ..sort();
    } else {
      if (data['months'] is! List ||
          (data['months'] as List).isEmpty ||
          !(data['months'] as List).every(validMonth)) {
        invalid('Invalid month register.');
      }
      months = List<String>.from(data['months'])..sort();
    }
    if (months.toSet().length != months.length ||
        months.last != data['activeMonth'] ||
        sales.any((s) => !months.contains(s.month))) {
      invalid('Sales and month register do not match.');
    }
    if (households.map((p) => p.id).toSet().length != households.length ||
        households.map((p) => p.rcNumber.toLowerCase()).toSet().length !=
            households.length) {
      invalid('Duplicate household or RC number.');
    }
    if (sales.map((s) => s.id).toSet().length != sales.length ||
        sales.map((s) => '${s.beneficiaryId}:${s.month}').toSet().length !=
            sales.length) {
      invalid('Duplicate distribution.');
    }
    return Register(months: months, households: households, sales: sales);
  }
  Register copy() => Register.fromJson(toJson());
  Sale? saleFor(String id, String month) => _saleIndex['$id:$month'];

  Json toJson() {
    final issued = sales.map((s) => '${s.beneficiaryId}:${s.month}').toSet();
    return {
      'version': 2,
      'activeMonth': months.last,
      'months': months,
      'beneficiaries':
          households
              .map(
                (p) => {
                  ...p.toJson(),
                  'statusByMonth': {
                    for (final month in months)
                      'status_${month.replaceAll('-', '_')}':
                          issued.contains('${p.id}:$month')
                              ? 'DISTRIBUTED'
                              : 'REMAINING',
                  },
                },
              )
              .toList(),
      'sales': sales.map((s) => s.toJson()).toList(),
    };
  }

  /// Idempotent replay against a freshly fetched remote register. Ambiguous
  /// simultaneous changes stop sync instead of silently replacing either side.
  void apply(Json operation) {
    switch (operation['type']) {
      case 'month':
        final month = operation['month'];
        if (!validMonth(month)) invalid('Invalid queued month.');
        if (!months.contains(month)) {
          months.add(month as String);
          months.sort();
        }
      case 'add':
        final incoming = Household.fromJson(
          Map<String, dynamic>.from(operation['household'] as Map),
        );
        for (final existing in households) {
          if (existing.id == incoming.id) {
            if (jsonEncode(existing.toJson()) ==
                jsonEncode(incoming.toJson())) {
              return;
            }
            throw StateError(
              'Sync conflict for RC ${incoming.rcNumber}. Export local data and reconcile the repository before retrying.',
            );
          }
          if (existing.rcNumber.toLowerCase() ==
              incoming.rcNumber.toLowerCase()) {
            throw StateError(
              'RC ${incoming.rcNumber} already exists on another device. Local changes are retained; reconcile duplicate records before retrying.',
            );
          }
        }
        households.add(incoming);
      case 'sale':
        final incoming = Sale.fromJson(
          Map<String, dynamic>.from(operation['sale'] as Map),
        );
        final existing = saleFor(incoming.beneficiaryId, incoming.month);
        if (existing != null) {
          if (jsonEncode(existing.toJson()) == jsonEncode(incoming.toJson())) {
            return;
          }
          throw StateError(
            'A different sale already exists for RC ${incoming.rcNumber} in ${monthLabel(incoming.month)}. Both records are retained on their devices; reconcile before retrying.',
          );
        }
        if (!households.any((p) => p.id == incoming.beneficiaryId)) {
          throw StateError(
            'The sale household is missing from the repository.',
          );
        }
        if (!months.contains(incoming.month)) {
          months.add(incoming.month);
          months.sort();
        }
        sales.add(incoming);
        _saleIndex['${incoming.beneficiaryId}:${incoming.month}'] = incoming;
      default:
        invalid('Unknown queued operation.');
    }
  }
}
