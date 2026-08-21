import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/protection/foreground_app_monitor.dart';
import 'package:smart_app_lock/protection/protected_app_matcher.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 5C: matching a foreground package against the protected-app
/// repository — protected, not-protected, and fail-closed unknown.
void main() {
  late AppContainer container;
  late ProtectedAppMatcher matcher;

  setUp(() {
    container = AppContainer.inMemory();
    matcher = container.protectedAppMatcher;
  });

  test('a protected app matches as protected', () async {
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: _addedAt,
      ),
    );

    final ProtectedMatch match = await matcher.match('com.whatsapp');
    expect(match.decision, ProtectedMatchDecision.protected);
    expect(match.isProtected, isTrue);
    expect(match.packageName, 'com.whatsapp');
  });

  test('an unprotected app matches as notProtected', () async {
    final ProtectedMatch match = await matcher.match('com.example.chat');
    expect(match.decision, ProtectedMatchDecision.notProtected);
    expect(match.isProtected, isFalse);
  });

  test('removing protection flips the decision live', () async {
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: _addedAt,
      ),
    );
    expect(
      (await matcher.match('com.whatsapp')).decision,
      ProtectedMatchDecision.protected,
    );

    await container.protectedApps.remove('com.whatsapp');
    expect(
      (await matcher.match('com.whatsapp')).decision,
      ProtectedMatchDecision.notProtected,
    );
  });

  test('an empty or blank package can never be protected', () async {
    expect(
      (await matcher.match('')).decision,
      ProtectedMatchDecision.notProtected,
    );
    expect(
      (await matcher.match('   ')).decision,
      ProtectedMatchDecision.notProtected,
    );
  });

  test('a repository failure yields unknown — never a guess', () async {
    final ProtectedAppMatcher failing =
        ProtectedAppMatcher(repository: _FailingRepository());

    final ProtectedMatch match = await failing.match('com.whatsapp');
    expect(match.decision, ProtectedMatchDecision.unknown);
    expect(match.isProtected, isFalse);
  });

  test('matchChange consumes a ForegroundAppChange directly', () async {
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: _addedAt,
      ),
    );

    final ProtectedMatch match = await matcher.matchChange(
      ForegroundAppChange(
        packageName: 'com.whatsapp',
        source: ForegroundDetectionSource.usageStats,
        at: _addedAt,
      ),
    );
    expect(match.decision, ProtectedMatchDecision.protected);
  });
}

/// [ProtectedAppsRepository] whose reads always fail — proves the
/// matcher maps failures to [ProtectedMatchDecision.unknown].
class _FailingRepository implements ProtectedAppsRepository {
  @override
  Future<Result<List<ProtectedApp>>> getProtectedApps() async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<void>> add(ProtectedApp app) async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<void>> remove(String packageName) async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<bool>> isProtected(String packageName) async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<int>> count() async =>
      Result.failure(StateError('database unavailable'));
}

final DateTime _addedAt = DateTime(2026, 8, 21, 9, 0);
