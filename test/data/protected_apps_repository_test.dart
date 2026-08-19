import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/protected_apps_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';

void main() {
  late ProtectedAppsRepository repo;

  final ProtectedApp whatsapp = ProtectedApp(
    packageName: 'com.whatsapp',
    label: 'WhatsApp',
    addedAt: DateTime(2026, 8, 19, 10, 0),
  );
  final ProtectedApp instagram = ProtectedApp(
    packageName: 'com.instagram',
    label: 'Instagram',
    addedAt: DateTime(2026, 8, 19, 11, 0),
    sortOrder: 1,
  );

  setUp(() {
    repo = ProtectedAppsRepositoryImpl(InMemoryLocalDatabase());
  });

  test('starts empty', () async {
    final result = await repo.count();
    expect(result.fold((int c) => c, (Object e) => -1), 0);
    final apps = await repo.getProtectedApps();
    expect(apps.valueOrNull, isEmpty);
  });

  test('add persists an app and count grows', () async {
    await repo.add(whatsapp);
    await repo.add(instagram);
    expect((await repo.count()).valueOrNull, 2);
    final apps = (await repo.getProtectedApps()).valueOrNull!;
    expect(apps.map((ProtectedApp a) => a.packageName).toSet(),
        <String>{'com.whatsapp', 'com.instagram'});
  });

  test('list is ordered by sortOrder then label', () async {
    // instagram has sortOrder 1 -> after whatsapp (0).
    await repo.add(instagram);
    await repo.add(whatsapp);
    final apps = (await repo.getProtectedApps()).valueOrNull!;
    expect(apps.first.packageName, 'com.whatsapp');
    expect(apps.last.packageName, 'com.instagram');
  });

  test('add is an upsert by package name', () async {
    await repo.add(whatsapp);
    await repo.add(
      whatsapp.copyWith(label: 'WhatsApp Messenger', sortOrder: 9),
    );
    expect((await repo.count()).valueOrNull, 1);
    final apps = (await repo.getProtectedApps()).valueOrNull!;
    expect(apps.single.label, 'WhatsApp Messenger');
    expect(apps.single.sortOrder, 9);
  });

  test('isProtected reflects the store', () async {
    expect((await repo.isProtected('com.whatsapp')).valueOrNull, isFalse);
    await repo.add(whatsapp);
    expect((await repo.isProtected('com.whatsapp')).valueOrNull, isTrue);
  });

  test('remove deletes the app', () async {
    await repo.add(whatsapp);
    await repo.remove('com.whatsapp');
    expect((await repo.count()).valueOrNull, 0);
    expect((await repo.isProtected('com.whatsapp')).valueOrNull, isFalse);
  });

  test('remove on a missing app is a safe no-op', () async {
    await repo.remove('com.unknown');
    expect((await repo.count()).valueOrNull, 0);
  });

  test('ProtectedApp JSON round-trip', () {
    final restored = ProtectedApp.fromJson(whatsapp.toJson());
    expect(restored.packageName, whatsapp.packageName);
    expect(restored.label, whatsapp.label);
    expect(restored.addedAt, whatsapp.addedAt);
    expect(restored.sortOrder, whatsapp.sortOrder);
  });
}
