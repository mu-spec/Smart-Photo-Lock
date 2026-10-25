import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_manager.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/apps/unprotect_gate.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';
import '../support/credential_change_grant.dart';

/// CR-2 regression: protection can be removed ONLY after Smart App Lock
/// app-credential authentication (PIN or pattern) verified by the real
/// credential manager. This covers both the single-app switch and bulk
/// Unprotect.
///
/// These are widget-level tests. "Process recreation" here means tearing
/// down the widget tree and booting a fresh container over the same
/// persisted stores. That is the same honest simulation used by
/// `process_recreation_test.dart`. It is not a real Android process death.
const String _pin = '1234';
const String _wrongPin = '9999';
const String _wa = 'com.whatsapp';
const String _ig = 'com.instagram';
const String _gm = 'com.gmail';

const List<AppEntry> _seed = <AppEntry>[
  AppEntry(packageName: _wa, label: 'WhatsApp'),
  AppEntry(packageName: _ig, label: 'Instagram'),
  AppEntry(packageName: _gm, label: 'Gmail'),
];

class _Disk {
  final InMemoryLocalDatabase database = InMemoryLocalDatabase();
  final InMemorySecretStore secretStore = InMemorySecretStore();
}

AppContainer _container(_Disk disk, {BiometricService? biometrics}) =>
    AppContainer.inMemory(
      apps: _seed,
      database: disk.database,
      secretStore: disk.secretStore,
      biometrics: biometrics,
    );

Future<void> _pumpApps(WidgetTester tester, AppContainer container) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: AppsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Protects [packages], enrols the PIN (unless [enrollPin] is false),
/// synchronises native, and mounts the Apps screen.
Future<AppContainer> _setUp(
  WidgetTester tester, {
  _Disk? disk,
  List<String> packages = const <String>[_wa],
  bool enrollPin = true,
  BiometricService? biometrics,
}) async {
  final AppContainer container =
      _container(disk ?? _Disk(), biometrics: biometrics);
  if (enrollPin) await container.auth.enrollPin(_pin);
  for (final String p in packages) {
    await container.protectedApps.add(
      ProtectedApp(packageName: p, label: p, addedAt: DateTime(2026, 10, 25)),
    );
  }
  await container.protectionBootstrap.synchronize();
  await _pumpApps(tester, container);
  return container;
}

Finder _switchFor(String p) => find.byKey(Key('app_toggle_$p'));
Finder _checkFor(String p) => find.byKey(Key('app_check_$p'));

Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final String digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$digit')));
    await tester.pumpAndSettle();
  }
}

Future<Set<String>> _persisted(AppContainer c) async =>
    ((await c.protectedApps.getProtectedApps()).valueOrNull ??
            const <ProtectedApp>[])
        .map((ProtectedApp a) => a.packageName)
        .toSet();

Set<String> _native(AppContainer c) =>
    (c.watcher as StaticWatcherService).protectedPackages;

bool _switchOn(WidgetTester tester, String p) =>
    tester.widget<Switch>(_switchFor(p)).value;

Future<void> _openBulkSelection(WidgetTester tester, List<String> pkgs) async {
  await tester.tap(find.byKey(const Key('apps_select_button')));
  await tester.pumpAndSettle();
  for (final String p in pkgs) {
    await tester.tap(_checkFor(p));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('apps_bulk_unprotect')));
  await tester.pumpAndSettle();
}

void main() {
  // ---------------------------------------------------------------------
  // Single-app switch
  // ---------------------------------------------------------------------
  group('CR-2 single-app unprotect', () {
    testWidgets('requires the PIN: the switch does not move before it',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester);
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(unprotectConfirmTitle), findsOneWidget);
      expect(await _persisted(c), <String>{_wa});
      expect(_native(c), contains(_wa));

      await _enterPin(tester, _pin);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(_switchOn(tester, _wa), isFalse);
      expect(await _persisted(c), isEmpty);
      expect(_native(c), isNot(contains(_wa)),
          reason: 'native configuration is re-synchronised');
      expect(find.text('WhatsApp${AppsScreen.unprotectedSnack}'), findsOneWidget);
    });

    testWidgets('Back (AppBar) cancels: protection unchanged',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester);
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(_switchOn(tester, _wa), isTrue);
      expect(await _persisted(c), <String>{_wa});
      expect(_native(c), contains(_wa));
      expect(find.text(AppsScreen.unprotectNotConfirmedMessage), findsOneWidget);
    });

    testWidgets('system Back cancels: protection unchanged',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester);
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(_switchOn(tester, _wa), isTrue);
      expect(await _persisted(c), <String>{_wa});
    });

    testWidgets('a wrong PIN never unprotects, and counts as a real failed '
        'attempt', (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester);
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      await _enterPin(tester, _wrongPin);

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(await _persisted(c), <String>{_wa});
      final CredentialState state = (await c.auth.status()).valueOrNull!;
      expect(state.failedAttempts, 1,
          reason: 'the confirmation shares the lock engine attempt counter');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_switchOn(tester, _wa), isTrue);
      expect(await _persisted(c), <String>{_wa});
    });

    testWidgets('an active lockout blocks even the correct PIN',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester);
      AuthAttemptResult? last;
      for (int i = 0; i < 20 && last is! AuthLockedOut; i++) {
        last = (await c.auth.authenticatePin(_wrongPin)).valueOrNull;
      }
      expect(last, isA<AuthLockedOut>());

      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
      // Attempt the correct PIN anyway (keys may be disabled).
      for (final String d in _pin.split('')) {
        final Finder key = find.byKey(Key('pin_key_$d'));
        if (key.evaluate().isNotEmpty) {
          await tester.tap(key, warnIfMissed: false);
          await tester.pump();
        }
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await _persisted(c), <String>{_wa});
      expect(_switchOn(tester, _wa), isTrue);
    });

    testWidgets('no app credential enrolled: denied without any prompt',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester, enrollPin: false);
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.byType(PatternUnlockScreen), findsNothing);
      expect(find.text(AppsScreen.unprotectNoCredentialMessage), findsOneWidget);
      expect(await _persisted(c), <String>{_wa});
      expect(_switchOn(tester, _wa), isTrue);
    });

    testWidgets('pattern-primary users confirm with their pattern',
        (WidgetTester tester) async {
      final AppContainer c = _container(_Disk());
      await c.auth.enrollPin(_pin);
      expect(
        (await c.auth.enrollPattern(
          const <int>[1, 2, 3, 6, 9],
          authorization: await grantWithPin(c.auth, _pin), // CR-3
        ))
            .isSuccess,
        isTrue,
      ); // the pattern is now primary
      await c.protectedApps.add(
        ProtectedApp(packageName: _wa, label: _wa, addedAt: DateTime(2026)),
      );
      await _pumpApps(tester, c);

      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      expect(find.byType(PatternUnlockScreen), findsOneWidget);
      expect(find.byType(PinUnlockScreen), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await _persisted(c), <String>{_wa});
    });

    testWidgets('biometric is never offered on the confirmation, even when '
        'enabled for app unlock (H-3 / app-credential policy)',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(
        tester,
        biometrics: const _FakeBiometricService(),
      );
      expect(
        (await c.auth.updateBiometricOptions(const BiometricOptions()))
            .isSuccess,
        isTrue,
      );
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await _persisted(c), <String>{_wa});
    });

    testWidgets('turning protection ON still needs no confirmation',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester);
      await tester.tap(_switchFor(_ig));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(await _persisted(c), <String>{_wa, _ig});
    });

    testWidgets('app switching during the confirmation authorizes nothing',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester);
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();

      for (final AppLifecycleState s in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget,
          reason: 'the confirmation is still required after returning');
      expect(await _persisted(c), <String>{_wa});

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await _persisted(c), <String>{_wa});
    });

    testWidgets('teardown mid-confirmation (simulated process recreation) '
        'removes nothing; the recreated app still protects',
        (WidgetTester tester) async {
      final _Disk disk = _Disk();
      final AppContainer first = await _setUp(tester, disk: disk);
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await _persisted(first), <String>{_wa});

      final AppContainer reborn = _container(disk);
      await _pumpApps(tester, reborn);
      expect(await _persisted(reborn), <String>{_wa});
      expect(_switchOn(tester, _wa), isTrue);
      // A fresh unprotect in the new process needs a fresh confirmation.
      await tester.tap(_switchFor(_wa));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------
  // Bulk Unprotect
  // ---------------------------------------------------------------------
  group('CR-2 bulk unprotect', () {
    testWidgets('one confirmation removes exactly the selected protected apps',
        (WidgetTester tester) async {
      final AppContainer c =
          await _setUp(tester, packages: <String>[_wa, _ig, _gm]);
      await _openBulkSelection(tester, <String>[_wa, _ig]);

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(await _persisted(c), <String>{_wa, _ig, _gm});
      await _enterPin(tester, _pin);

      expect(await _persisted(c), <String>{_gm});
      expect(_native(c), <String>{_gm});
      expect(find.text(AppsScreen.bulkUnprotected(2)), findsOneWidget);
    });

    testWidgets('cancel removes nothing and keeps the selection',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester, packages: <String>[_wa, _ig]);
      await _openBulkSelection(tester, <String>[_wa, _ig]);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(await _persisted(c), <String>{_wa, _ig});
      expect(_native(c), <String>{_wa, _ig});
      expect(find.text(AppsScreen.selectedCount(2)), findsOneWidget);
      expect(find.text(AppsScreen.unprotectNotConfirmedMessage), findsOneWidget);
      // The bulk bar is usable again (not stuck busy): a retry asks for a
      // fresh confirmation, and the correct PIN then completes it. Let the
      // denial snackbar (which overlays the bulk bar) time out first.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apps_bulk_unprotect')));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _enterPin(tester, _pin);
      expect(await _persisted(c), isEmpty);
    });

    testWidgets('a wrong PIN then cancel removes nothing',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester, packages: <String>[_wa, _ig]);
      await _openBulkSelection(tester, <String>[_wa, _ig]);
      await _enterPin(tester, _wrongPin);
      expect(await _persisted(c), <String>{_wa, _ig});
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await _persisted(c), <String>{_wa, _ig});
    });

    testWidgets('no app credential: bulk is denied without any prompt',
        (WidgetTester tester) async {
      final AppContainer c = await _setUp(
        tester,
        packages: <String>[_wa, _ig],
        enrollPin: false,
      );
      await _openBulkSelection(tester, <String>[_wa, _ig]);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.text(AppsScreen.unprotectNoCredentialMessage), findsOneWidget);
      expect(await _persisted(c), <String>{_wa, _ig});
    });

    testWidgets('a selection with no protected apps needs no confirmation '
        '(nothing is removed)', (WidgetTester tester) async {
      final AppContainer c = await _setUp(tester, packages: <String>[_wa]);
      await _openBulkSelection(tester, <String>[_ig, _gm]);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(await _persisted(c), <String>{_wa});
      expect(find.text(AppsScreen.bulkUnprotected(0)), findsOneWidget);
    });

    testWidgets('teardown mid-confirmation removes nothing',
        (WidgetTester tester) async {
      final _Disk disk = _Disk();
      final AppContainer c =
          await _setUp(tester, disk: disk, packages: <String>[_wa, _ig]);
      await _openBulkSelection(tester, <String>[_wa, _ig]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await _persisted(c), <String>{_wa, _ig});
      expect(await _persisted(_container(disk)), <String>{_wa, _ig});
    });
  });

  // ---------------------------------------------------------------------
  // The gate itself: UI state is never authentication; proofs are scoped
  // ---------------------------------------------------------------------
  group('CR-2 gate', () {
    testWidgets('a route popped with `true` is NOT authentication, and a PIN '
        'verified on another surface does not count',
        (WidgetTester tester) async {
      final _Harness h = await _Harness.pump(tester);
      await h.request(<String>{_wa});
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      // Another surface (for example the lock challenge) verifies the PIN
      // through the real manager directly. This must not leak into the gate.
      expect(
        (await h.container.auth.authenticatePin(_pin)).valueOrNull,
        isA<AuthSuccess>(),
      );
      // Forge the UI outcome.
      h.navigatorKey.currentState!.pop(true);
      await tester.pumpAndSettle();

      expect(h.result!.isAuthorized, isFalse);
      expect(h.result!.denial, UnprotectDenial.notAuthenticated);
    });

    testWidgets('an unreadable credential state fails closed without a prompt',
        (WidgetTester tester) async {
      final _Harness h =
          await _Harness.pump(tester, credentials: _FailingStatusManager());
      await h.request(<String>{_wa});
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(h.result!.denial, UnprotectDenial.credentialUnavailable);
    });

    testWidgets('a proof is package-scoped, single-use, and expires',
        (WidgetTester tester) async {
      DateTime now = DateTime(2026, 10, 25, 12);
      final _Harness h = await _Harness.pump(tester, clock: () => now);
      for (final String p in <String>[_wa, _ig, _gm]) {
        await h.container.protectedApps.add(
          ProtectedApp(packageName: p, label: p, addedAt: DateTime(2026)),
        );
      }
      await h.request(<String>{_wa, _ig});
      await _enterPin(tester, _pin);
      final UnprotectAuthorization auth = h.result!.authorization!;
      final repo = h.container.protectedApps;

      // Out of scope.
      expect((await removeProtectionWith(auth, repo, _gm, clock: () => now))
          .isFailure, isTrue);
      // In scope, fresh.
      expect((await removeProtectionWith(auth, repo, _wa, clock: () => now))
          .isSuccess, isTrue);
      // Single use.
      await h.container.protectedApps.add(
        ProtectedApp(packageName: _wa, label: _wa, addedAt: DateTime(2026)),
      );
      expect((await removeProtectionWith(auth, repo, _wa, clock: () => now))
          .isFailure, isTrue);
      // Expired.
      now = now.add(UnprotectAuthorization.maxAge + const Duration(seconds: 1));
      expect((await removeProtectionWith(auth, repo, _ig, clock: () => now))
          .isFailure, isTrue);
      // A clock moved backwards is invalid too.
      expect(
        auth.allows(_ig, DateTime(2026, 10, 25, 11)),
        isFalse,
      );
      expect(await _persisted(h.container), <String>{_wa, _ig, _gm});
    });
  });
}

/// Calls [requestUnprotectAuthorization] directly.
class _Harness {
  _Harness(this.tester, this.container, this.navigatorKey, this.credentials,
      this.clock);

  final WidgetTester tester;
  final AppContainer container;
  final GlobalKey<NavigatorState> navigatorKey;
  final CredentialManager credentials;
  final DateTime Function()? clock;
  UnprotectRequestResult? result;

  static Future<_Harness> pump(
    WidgetTester tester, {
    CredentialManager? credentials,
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer container = _container(_Disk());
    await container.auth.enrollPin(_pin);
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          navigatorKey: key,
          theme: AppTheme.dark,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    return _Harness(
        tester, container, key, credentials ?? container.auth, clock);
  }

  Future<void> request(Set<String> packages) async {
    result = null;
    requestUnprotectAuthorization(
      navigator: navigatorKey.currentState!,
      credentials: credentials,
      packages: packages,
      clock: clock,
    ).then((UnprotectRequestResult r) => result = r);
    await tester.pumpAndSettle();
  }
}

class _FakeBiometricService implements BiometricService {
  const _FakeBiometricService();

  @override
  Future<Result<bool>> isSupported() async => Result.success(true);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(const <BiometricKind>{BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async =>
      Result.success(true);
}

class _FailingStatusManager implements CredentialManager {
  @override
  Future<Result<CredentialState>> status() async =>
      Result.failure(StateError('secure storage unavailable'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used: ${invocation.memberName}');
}
