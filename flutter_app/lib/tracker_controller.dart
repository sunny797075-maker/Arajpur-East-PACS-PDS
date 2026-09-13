import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'github_sync.dart';
import 'local_store.dart';
import 'models.dart';

class TrackerController extends ChangeNotifier {
  final StateStore store;
  final GitHubSync github;
  Register data = Register.empty();
  List<Json> _pending = [];
  String selectedMonth = monthKey(DateTime.now());
  String syncStatus = 'Offline ready · Add a GitHub token in Settings to sync.';
  String? _token;
  bool syncing = false;
  bool _disposed = false;
  bool _blocked = false;
  int _failures = 0;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _tail = Future.value();
  Timer? _timer;
  TrackerController(this.store, this.github);
  int get pendingCount => _pending.length;
  bool get hasToken => _token != null;
  int get served =>
      data.households
          .where((p) => data.saleFor(p.id, selectedMonth) != null)
          .length;
  double get distributedKg =>
      data.sales
          .where((s) => s.month == selectedMonth)
          .fold<int>(
            0,
            (sum, s) => sum + (s.wheat * 100).round() + (s.rice * 100).round(),
          ) /
      100;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Json _envelope(Register register, List<Json> pending) => {
    'schema': 1,
    'data': register.toJson(),
    'pending': pending,
    'selectedMonth': selectedMonth,
  };
  Future<void> initialize({String? token, bool automaticRetry = true}) async {
    final saved = await store.read();
    if (saved != null) {
      if (saved['schema'] != 1 || saved['pending'] is! List) {
        throw const FormatException(
          'Local data cannot be read. It has not been replaced.',
        );
      }
      data = Register.fromJson(Map<String, dynamic>.from(saved['data'] as Map));
      _pending =
          (saved['pending'] as List)
              .map((op) => Map<String, dynamic>.from(op as Map))
              .toList();
      final probe = data.copy();
      final ids = <String>{};
      for (final op in _pending) {
        final id = requiredText(op, 'operationId', 160);
        if (!ids.add(id)) {
          throw const FormatException('Duplicate local queue operation.');
        }
        probe.apply(op);
      }
      if (data.months.contains(saved['selectedMonth'])) {
        selectedMonth = saved['selectedMonth'] as String;
      }
    }
    final current = monthKey(DateTime.now());
    for (final month in [adjacentMonth(current, -1), current]) {
      if (!data.months.contains(month)) {
        final operation = {
          'operationId': newId(),
          'type': 'month',
          'month': month,
        };
        data.apply(operation);
        _pending.add(operation);
      }
    }
    await store.write(_envelope(data, _pending));
    _token = token?.trim().isNotEmpty == true ? token!.trim() : null;
    if (automaticRetry) {
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(sync()),
      );
      unawaited(sync());
    }
    changed();
  }

  void setToken(String? token) {
    _token = token?.trim().isNotEmpty == true ? token!.trim() : null;
    _blocked = false;
    _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
    if (_token == null) {
      syncStatus = 'Sync disconnected. Transactions stay on this device.';
    }
    changed();
    unawaited(sync(force: true));
  }

  Future<void> selectMonth(String month) => _exclusive(() async {
    if (!data.months.contains(month)) throw StateError('Unknown month.');
    final old = selectedMonth;
    selectedMonth = month;
    try {
      await store.write(_envelope(data, _pending));
    } catch (_) {
      selectedMonth = old;
      rethrow;
    }
    changed();
  });
  Future<void> _enqueue(Json operation) async {
    await _exclusive(() async {
      final next = data.copy();
      next.apply(operation);
      final pending = [..._pending, operation];
      await store.write(_envelope(next, pending));
      data = next;
      _pending = pending;
      syncStatus =
          hasToken
              ? 'Saved on device · $pendingCount changes waiting to sync.'
              : 'Saved on device · Add a token in Settings to sync.';
      changed();
    });
    unawaited(sync());
  }

  Future<void> addHousehold(Household household) => _enqueue({
    'operationId': newId(),
    'type': 'add',
    'household': household.toJson(),
  });
  Future<void> recordSale(Household household, String month) async {
    // Capture the month before showing a confirmation; never use a later selection.
    await _exclusive(() async {
      if (!data.months.contains(month) ||
          !data.households.any((p) => p.id == household.id)) {
        throw StateError(
          'The selected family or month is no longer available.',
        );
      }
      if (data.saleFor(household.id, month) != null) {
        throw StateError(
          'This family has already received ration for ${monthLabel(month)}.',
        );
      }
      final sale = Sale(
        id: newId(),
        beneficiaryId: household.id,
        month: month,
        rcNumber: household.rcNumber,
        headName: household.headName,
        recordedAt: DateTime.now().toUtc().toIso8601String(),
        wheat: household.wheat,
        rice: household.rice,
      );
      final operation = {
        'operationId': newId(),
        'type': 'sale',
        'sale': sale.toJson(),
      };
      final next = data.copy()..apply(operation),
          pending = [..._pending, operation];
      await store.write(_envelope(next, pending));
      data = next;
      _pending = pending;
      syncStatus =
          'Sale saved on device · $pendingCount changes waiting to sync.';
      changed();
    });
    unawaited(sync());
  }

  Future<void> startMonth() async {
    final month = adjacentMonth(data.months.last, 1);
    await _enqueue({'operationId': newId(), 'type': 'month', 'month': month});
    await selectMonth(month);
  }

  String exportBackup() =>
      const JsonEncoder.withIndent('  ').convert(_envelope(data, _pending));
  Future<void> sync({bool force = false}) async {
    if (_disposed ||
        syncing ||
        _token == null ||
        (!force && (_blocked || DateTime.now().isBefore(_retryAfter)))) {
      return;
    }
    syncing = true;
    syncStatus = 'Syncing with GitHub…';
    changed();
    final token = _token!;
    try {
      final captured = await _exclusive(
        () async => (List<Json>.from(_pending), data.copy()),
      );
      final snapshot = captured.$1;
      final merged = await github.mergeAndPush(
        token,
        snapshot,
        baseline: captured.$2,
      );
      await _exclusive(() async {
        final acknowledged = snapshot.map((op) => op['operationId']).toSet();
        final remaining =
            _pending
                .where((op) => !acknowledged.contains(op['operationId']))
                .toList();
        for (final op in remaining) {
          merged.apply(op);
        }
        // Empty remote registers must not remove locally available calendar months.
        for (final month in data.months) {
          if (!merged.months.contains(month)) {
            final op = {
              'operationId': newId(),
              'type': 'month',
              'month': month,
            };
            merged.apply(op);
            remaining.add(op);
          }
        }
        await store.write(_envelope(merged, remaining));
        data = merged;
        _pending = remaining;
        if (!data.months.contains(selectedMonth)) {
          selectedMonth = data.months.last;
        }
      });
      _failures = 0;
      _blocked = false;
      _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
      syncStatus =
          hasToken
              ? (pendingCount == 0
                  ? 'All changes synced · ${DateTime.now().toLocal().toString().substring(11, 16)}'
                  : '$pendingCount new changes queued for sync.')
              : 'Sync disconnected.';
    } catch (error) {
      _failures++;
      _retryAfter = DateTime.now().add(
        Duration(seconds: (30 * (1 << _failures.clamp(0, 4))).clamp(30, 900)),
      );
      if (error is SyncFailure) {
        _blocked = !error.retryable;
        syncStatus = error.message;
      } else if (error is StateError || error is FormatException) {
        _blocked = true;
        syncStatus = error.toString();
      } else {
        syncStatus =
            'Could not reach GitHub or save its response. $pendingCount changes remain queued; automatic retry is enabled.';
      }
    } finally {
      syncing = false;
      changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
