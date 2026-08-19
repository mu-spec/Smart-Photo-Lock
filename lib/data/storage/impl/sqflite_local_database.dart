import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/protected_app.dart';
import '../../../profiles/lock_profile.dart';
import '../../../rules/lock_rule.dart';
import '../local_database.dart';

/// Production [LocalDatabase] backed by SQLite (`sqflite`).
///
/// Schema v1:
/// ```
/// protected_apps(package_name PK, label, added_at, sort_order)
/// security_settings(key PK, value, updated_at)
/// profiles(id PK, name, description, is_active, locked_packages JSON)
/// lock_rules(id PK, type, package_name, start_minute, end_minute,
///            max_launches, enabled)
/// ```
/// Future schema changes bump [_schemaVersion] and extend `_onUpgrade`.
class SqfliteLocalDatabase implements LocalDatabase {
  static const String _dbName = 'smart_app_lock.db';
  static const int _schemaVersion = 1;

  Database? _db;

  @override
  int get schemaVersion => _schemaVersion;

  @override
  Future<void> init() async {
    _db ??= await _open();
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<Database> get _database async => _db ??= await _open();

  Future<Database> _open() async {
    final String path = p.join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: _schemaVersion,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE protected_apps (
            package_name TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            added_at INTEGER NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE security_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            is_active INTEGER NOT NULL DEFAULT 0,
            locked_packages TEXT NOT NULL DEFAULT '[]'
          )
        ''');
        await db.execute('''
          CREATE TABLE lock_rules (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            package_name TEXT,
            start_minute INTEGER,
            end_minute INTEGER,
            max_launches INTEGER,
            enabled INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_protected_apps_sort '
          'ON protected_apps(sort_order)',
        );
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        // No migrations yet — schema v1 is the foundation.
      },
    );
  }

  // -- protected applications ---------------------------------------------

  @override
  Future<List<ProtectedApp>> getProtectedApps() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'protected_apps',
      orderBy: 'sort_order ASC, label ASC',
    );
    return rows.map(_protectedAppFromRow).toList();
  }

  @override
  Future<void> saveProtectedApp(ProtectedApp app) async {
    final Database db = await _database;
    await db.insert(
      'protected_apps',
      <String, Object?>{
        'package_name': app.packageName,
        'label': app.label,
        'added_at': app.addedAt.millisecondsSinceEpoch,
        'sort_order': app.sortOrder,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> removeProtectedApp(String packageName) async {
    final Database db = await _database;
    await db.delete(
      'protected_apps',
      where: 'package_name = ?',
      whereArgs: <Object?>[packageName],
    );
  }

  ProtectedApp _protectedAppFromRow(Map<String, Object?> row) => ProtectedApp(
        packageName: row['package_name'] as String,
        label: row['label'] as String,
        addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_at'] as int),
        sortOrder: row['sort_order'] as int? ?? 0,
      );

  // -- security settings (key-value) ----------------------------------------

  @override
  Future<String?> getSetting(String key) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'security_settings',
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<Map<String, String>> getAllSettings() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query('security_settings');
    return <String, String>{
      for (final Map<String, Object?> row in rows)
        row['key'] as String: row['value'] as String,
    };
  }

  @override
  Future<void> setSetting(String key, String value) async {
    final Database db = await _database;
    await db.insert(
      'security_settings',
      <String, Object?>{
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> removeSetting(String key) async {
    final Database db = await _database;
    await db.delete(
      'security_settings',
      where: 'key = ?',
      whereArgs: <Object?>[key],
    );
  }

  // -- lock profiles -------------------------------------------------------

  @override
  Future<List<LockProfile>> getProfiles() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows =
        await db.query('profiles', orderBy: 'name ASC');
    return rows.map(_profileFromRow).toList();
  }

  @override
  Future<void> saveProfile(LockProfile profile) async {
    final Database db = await _database;
    await db.transaction((Transaction txn) async {
      if (profile.isActive) {
        // Enforce the single-active invariant.
        await txn.update(
          'profiles',
          <String, Object?>{'is_active': 0},
          where: 'id != ?',
          whereArgs: <Object?>[profile.id],
        );
      }
      await txn.insert(
        'profiles',
        <String, Object?>{
          'id': profile.id,
          'name': profile.name,
          'description': profile.description,
          'is_active': profile.isActive ? 1 : 0,
          'locked_packages': jsonEncode(profile.lockedPackages),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    final Database db = await _database;
    await db.delete(
      'profiles',
      where: 'id = ?',
      whereArgs: <Object?>[profileId],
    );
  }

  LockProfile _profileFromRow(Map<String, Object?> row) => LockProfile(
        id: row['id'] as String,
        name: row['name'] as String,
        description: row['description'] as String?,
        isActive: (row['is_active'] as int? ?? 0) == 1,
        lockedPackages: (jsonDecode(row['locked_packages'] as String)
                as List<dynamic>)
            .cast<String>(),
      );

  // -- lock rules ----------------------------------------------------------

  @override
  Future<List<LockRule>> getRules() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query('lock_rules');
    return rows.map(_ruleFromRow).toList();
  }

  @override
  Future<void> saveRules(List<LockRule> rules) async {
    final Database db = await _database;
    await db.transaction((Transaction txn) async {
      await txn.delete('lock_rules');
      for (final LockRule rule in rules) {
        await txn.insert('lock_rules', <String, Object?>{
          'id': rule.id,
          'type': rule.type.name,
          'package_name': rule.packageName,
          'start_minute': rule.startMinuteOfDay,
          'end_minute': rule.endMinuteOfDay,
          'max_launches': rule.maxLaunchesPerDay,
          'enabled': rule.enabled ? 1 : 0,
        });
      }
    });
  }

  LockRule _ruleFromRow(Map<String, Object?> row) => LockRule(
        id: row['id'] as String,
        type: LockRuleType.values.byName(row['type'] as String),
        packageName: row['package_name'] as String?,
        startMinuteOfDay: row['start_minute'] as int?,
        endMinuteOfDay: row['end_minute'] as int?,
        maxLaunchesPerDay: row['max_launches'] as int?,
        enabled: (row['enabled'] as int? ?? 1) == 1,
      );
}
