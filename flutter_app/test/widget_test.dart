import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pds_ration_tracker/models.dart';
import 'package:pds_ration_tracker/local_store.dart';
import 'package:pds_ration_tracker/github_sync.dart';
import 'package:pds_ration_tracker/tracker_controller.dart';
import 'package:pds_ration_tracker/main.dart';

class MemoryStore implements StateStore {
  Json? saved;
  bool fail = false;
  @override
  Future<Json?> read() async =>
      saved == null ? null : jsonDecode(jsonEncode(saved)) as Json;
  @override
  Future<void> write(Json envelope) async {
    if (fail) throw StateError('Disk full');
    saved = jsonDecode(jsonEncode(envelope)) as Json;
  }
}

const person = Household(
  id: 'family1',
  rcNumber: '00123',
  headName: 'Asha Devi',
  phone: '9876543210',
  members: 4,
  wheat: 10,
  rice: 10,
);
http.Response metadata() =>
    http.Response(jsonEncode({'private': true, 'default_branch': 'main'}), 200);
http.Response contents(Register data, [String sha = 'sha1']) => http.Response(
  jsonEncode({
    'type': 'file',
    'encoding': 'base64',
    'size': 300,
    'sha': sha,
    'content': base64Encode(utf8.encode(jsonEncode(data.toJson()))),
  }),
  200,
);
Future<TrackerController> controller(
  MemoryStore store, [
  http.Client? client,
]) async {
  final result = TrackerController(
    store,
    GitHubSync(
      client ?? MockClient((_) async => throw http.ClientException('Offline')),
    ),
  );
  await result.initialize(automaticRetry: false);
  return result;
}

void main() {
  test(
    'sale status is isolated by month and duplicate sales are refused',
    () async {
      final tracker = await controller(MemoryStore());
      addTearDown(tracker.dispose);
      await tracker.addHousehold(person);
      final current = tracker.selectedMonth,
          previous = adjacentMonth(current, -1);
      await tracker.recordSale(person, current);
      expect(tracker.served, 1);
      await tracker.selectMonth(previous);
      expect(tracker.served, 0);
      await tracker.recordSale(person, previous);
      expect(tracker.served, 1);
      await expectLater(tracker.recordSale(person, previous), throwsStateError);
      expect(tracker.data.sales.length, 2);
      expect(
        tracker.data
            .toJson()['beneficiaries'][0]['statusByMonth']['status_${current.replaceAll('-', '_')}'],
        'DISTRIBUTED',
      );
    },
  );
  test(
    'register and offline queue survive a controller restart together',
    () async {
      final store = MemoryStore(), first = await controller(MemoryStore());
      first.dispose();
      final tracker = await controller(store);
      await tracker.addHousehold(person);
      await tracker.recordSale(person, tracker.selectedMonth);
      tracker.dispose();
      final reopened = await controller(store);
      addTearDown(reopened.dispose);
      expect(reopened.pendingCount, 2);
      expect(reopened.served, 1);
      expect(reopened.data.households.single.rcNumber, '00123');
    },
  );
  test('disk failure leaves state and queue unchanged', () async {
    final store = MemoryStore(), tracker = await controller(MemoryStore());
    tracker.dispose();
    final app = await controller(store);
    addTearDown(app.dispose);
    store.fail = true;
    await expectLater(app.addHousehold(person), throwsStateError);
    expect(app.pendingCount, 0);
    expect(app.data.households, isEmpty);
  });
  test(
    'offline request keeps queue, successful retry merges and acknowledges it',
    () async {
      var online = false;
      Register remote = Register.empty();
      final client = MockClient((request) async {
        if (!online) throw http.ClientException('Offline');
        if (!request.url.path.endsWith('data.json')) return metadata();
        if (request.method == 'GET') return contents(remote);
        final body = jsonDecode(request.body) as Json;
        expect(body['sha'], 'sha1');
        remote = Register.fromJson(
          jsonDecode(utf8.decode(base64Decode(body['content']))) as Json,
        );
        return http.Response('{}', 200);
      });
      final app = await controller(MemoryStore(), client);
      addTearDown(app.dispose);
      await app.addHousehold(person);
      app.setToken('test-token');
      while (app.syncing) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(app.pendingCount, 1);
      online = true;
      await app.sync(force: true);
      expect(app.pendingCount, 0);
      expect(remote.households.single.id, person.id);
    },
  );
  test(
    'GitHub SHA conflict fetches latest data and retries without erasing other households',
    () async {
      var puts = 0;
      final remote = Register.empty();
      remote.households.add(
        const Household(
          id: 'other',
          rcNumber: '00999',
          headName: 'Other family',
          phone: '9876543211',
          members: 2,
          wheat: 5,
          rice: 5,
        ),
      );
      final sync = GitHubSync(
        MockClient((request) async {
          if (!request.url.path.endsWith('data.json')) return metadata();
          if (request.method == 'GET') return contents(remote, 'sha$puts');
          puts++;
          if (puts == 1) return http.Response('{}', 409);
          final body = jsonDecode(request.body) as Json;
          expect(body['sha'], 'sha1');
          return http.Response('{}', 200);
        }),
      );
      final result = await sync.mergeAndPush('test', [
        {'operationId': 'add1', 'type': 'add', 'household': person.toJson()},
      ]);
      expect(puts, 2);
      expect(result.households.length, 2);
    },
  );
  test('malformed remote file is never overwritten', () async {
    var puts = 0;
    final sync = GitHubSync(
      MockClient((request) async {
        if (request.method == 'PUT') puts++;
        if (!request.url.path.endsWith('data.json')) return metadata();
        return http.Response(
          jsonEncode({
            'type': 'file',
            'encoding': 'base64',
            'size': 5,
            'sha': 's',
            'content': base64Encode(utf8.encode('{}')),
          }),
          200,
        );
      }),
    );
    await expectLater(
      sync.mergeAndPush('test', [
        {'operationId': 'add1', 'type': 'add', 'household': person.toJson()},
      ]),
      throwsA(isA<SyncFailure>()),
    );
    expect(puts, 0);
  });
  test(
    'lost PUT response is safe to replay without duplicating sales',
    () async {
      var loseResponse = true;
      Register remote = Register.empty();
      final client = MockClient((request) async {
        if (!request.url.path.endsWith('data.json')) return metadata();
        if (request.method == 'GET') return contents(remote);
        final body = jsonDecode(request.body) as Json;
        remote = Register.fromJson(
          jsonDecode(utf8.decode(base64Decode(body['content']))) as Json,
        );
        if (loseResponse) {
          loseResponse = false;
          throw http.ClientException('Response lost');
        }
        return http.Response('{}', 200);
      });
      final app = await controller(MemoryStore(), client);
      addTearDown(app.dispose);
      await app.addHousehold(person);
      await app.recordSale(person, app.selectedMonth);
      app.setToken('test');
      while (app.syncing) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(app.pendingCount, 2);
      expect(remote.sales.length, 1);
      await app.sync(force: true);
      expect(app.pendingCount, 0);
      expect(remote.sales.length, 1);
    },
  );
  test('simultaneous local changes during upload stay queued', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final app = await controller(
      MemoryStore(),
      MockClient((request) async {
        if (!request.url.path.endsWith('data.json')) return metadata();
        if (request.method == 'GET') return contents(Register.empty());
        entered.complete();
        await release.future;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(app.dispose);
    await app.addHousehold(person);
    app.setToken('test');
    await entered.future;
    await app.recordSale(person, app.selectedMonth);
    release.complete();
    while (app.syncing) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(app.pendingCount, 1);
    expect(app.served, 1);
  });
  test(
    'missing previously synced remote records cannot erase local history',
    () async {
      final baseline = Register.empty()..households.add(person);
      final sync = GitHubSync(
        MockClient((request) async {
          if (!request.url.path.endsWith('data.json')) return metadata();
          return http.Response('{}', 404);
        }),
      );
      await expectLater(
        sync.mergeAndPush('test', [], baseline: baseline),
        throwsA(isA<SyncFailure>()),
      );
      expect(baseline.households.single.id, person.id);
    },
  );
  testWidgets(
    'mobile header and dashboard render without clipping at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = await controller(MemoryStore());
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(home: TrackerScreen(controller: app)),
      );
      await tester.pump();
      expect(find.text('Arajpur East PACS PDS'), findsOneWidget);
      expect(find.text('Distribution month'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
