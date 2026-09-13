import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'models.dart';

abstract class StateStore {
  Future<Json?> read();
  Future<void> write(Json envelope);
}

/// SQLite commits the register and outbox together. Preferences are a fast
/// secondary cache, never the only copy of an unuploaded ration transaction.
class DeviceStore implements StateStore {
  final Database database;
  final SharedPreferencesAsync preferences;
  DeviceStore(this.database, this.preferences);
  static Future<DeviceStore> open() async {
    final root = await getDatabasesPath();
    final db = await openDatabase(
      '$root/pds_tracker.db',
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA synchronous = FULL');
      },
      onCreate:
          (db, version) => db.execute(
            'CREATE TABLE state (id INTEGER PRIMARY KEY CHECK (id = 1), body TEXT NOT NULL)',
          ),
    );
    return DeviceStore(db, SharedPreferencesAsync());
  }

  @override
  Future<Json?> read() async {
    final rows = await database.query('state', where: 'id = ?', whereArgs: [1]);
    final raw =
        rows.isNotEmpty
            ? rows.first['body'] as String
            : await preferences.getString('pds.envelope.v1');
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  @override
  Future<void> write(Json envelope) async {
    final raw = jsonEncode(envelope);
    await database.transaction(
      (txn) => txn.insert('state', {
        'id': 1,
        'body': raw,
      }, conflictAlgorithm: ConflictAlgorithm.replace),
    );
    // A failed cache write must not invalidate a successful durable commit.
    try {
      await preferences.setString('pds.envelope.v1', raw);
    } catch (_) {
      /* SQLite remains authoritative. */
    }
  }
}
