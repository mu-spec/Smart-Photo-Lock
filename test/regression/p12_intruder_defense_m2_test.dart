// Phase 12 / Milestone 2 — intruder evidence + alarm, end-to-end through
// the production AppContainer wiring, the real lock challenge host and the
// real Security screen.
//
// SIMULATED: Flutter widget tests with in-memory platform fakes. The camera
// and audio are a fake IntruderEvidenceService — NO device camera, Camera2,
// ToneGenerator, privacy indicator or permission dialog is exercised here.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_service.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

import '../support/intruder_fixtures.dart';

const String _app = 'com.bank.app';
const String _pin = '482916';

void main() {
  Future<AppContainer> pumpApp(WidgetTester tester, AppContainer c) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SmartAppLockApp(container: c));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> protect(AppContainer c) async {
    await c.protectedApps.add(ProtectedApp(
      packageName: _app,
      label: _app,
      addedAt: DateTime(2026, 10, 22),
      securityLevel: AppSecurityLevel.defaultLevel,
    ));
    await c.protectionBootstrap.synchronize();
  }

  Future<void> openApp(WidgetTester tester, AppContainer c) async {
    (c.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(_app);
    await tester.pumpAndSettle();
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    await tester.pump(const Duration(milliseconds: 250));
    for (final String d in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester, AppContainer c) async {
    await tester.pumpAndSettle();
    await c.intruderMonitor.idle();
    await c.intruderDefense.idle();
    await tester.pumpAndSettle();
  }

  Object? sessionFor(AppContainer c) =>
      (c.accessController as DefaultAccessController).sessionFor(_app);

  int launches(AppContainer c) =>
      (c.installedAppsService as StaticInstalledAppsService).launchAppCalls;

  group('protected-app challenge (real host, fake camera/alarm)', () {
    testWidgets(
        'opted in: the 3rd wrong PIN captures ONE photo keyed by that event; '
        'the app stays locked and the cooldown is unchanged',
        (WidgetTester tester) async {
      final GatedEvidenceService fake = GatedEvidenceService()
        ..permission = CameraPermissionState.granted;
      final AppContainer c =
          await pumpApp(tester, AppContainer.inMemory(intruderEvidence: fake));
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings
          .write(const IntruderDefenseSettings(evidenceEnabled: true));
      await protect(c);
      await openApp(tester, c);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      for (final String p in <String>['111111', '222222', '333333']) {
        await typePin(tester, p);
        await settle(tester, c);
      }
      final FailedAttemptEvent third =
          (await c.intruderMonitor.snapshot())!.events.last;
      expect(third.consecutiveFailures, 3);
      expect(fake.captures, 1);
      final EvidenceItem item = (await c.intruderEvidence.list()).single;
      expect(item.seq, third.seq);
      expect(item.packageName, _app);
      expect(fake.permissionRequests, 0, reason: 'never asked on a failure');

      expect(sessionFor(c), isNull);
      expect(launches(c), 0);
      expect((await c.auth.status()).valueOrNull!.lockedOutUntil, isNotNull);

      // Attempts during the cooldown are blocked, not recorded: no capture.
      await typePin(tester, '444444');
      await settle(tester, c);
      expect(fake.captures, 1);
      expect(find.byType(Image), findsNothing,
          reason: 'no evidence is ever shown on the challenge');
    });

    testWidgets('default (not opted in): no camera, alarm or permission use',
        (WidgetTester tester) async {
      final GatedEvidenceService fake = GatedEvidenceService()
        ..permission = CameraPermissionState.granted;
      final AppContainer c =
          await pumpApp(tester, AppContainer.inMemory(intruderEvidence: fake));
      await c.auth.enrollPin(_pin);
      await protect(c);
      await openApp(tester, c);
      for (final String p in <String>['111111', '222222', '333333']) {
        await typePin(tester, p);
        await settle(tester, c);
      }
      expect(fake.captures + fake.alarmStarts + fake.permissionRequests, 0);
      expect(await c.intruderEvidence.list(), isEmpty);
    });

    testWidgets(
        'a crashing camera/alarm platform never blocks the correct PIN; the '
        'owner success stops the alarm', (WidgetTester tester) async {
      final GatedEvidenceService fake = GatedEvidenceService()
        ..permission = CameraPermissionState.granted
        ..onCapture = () => throw StateError('camera HAL crashed');
      final AppContainer c =
          await pumpApp(tester, AppContainer.inMemory(intruderEvidence: fake));
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings.write(const IntruderDefenseSettings(
          evidenceEnabled: true, alarmEnabled: true, threshold: 1));
      await protect(c);
      await openApp(tester, c);

      await typePin(tester, '111111');
      await settle(tester, c);
      expect(fake.alarmPlaying, isTrue);
      expect(c.intruderDefense.status.errors, 1);
      expect(sessionFor(c), isNull);

      await typePin(tester, _pin);
      await settle(tester, c);
      expect(sessionFor(c), isNotNull, reason: 'verdict unaffected');
      expect(launches(c), 1);
      expect(fake.alarmPlaying, isFalse);
      expect(fake.alarmStops, 1);
      expect(fake.captures, 1, reason: 'never on success');
    });
  });

  group('owner consent on the Security screen', () {
    Future<void> pumpSecurity(WidgetTester tester, AppContainer c) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark,
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Finder switchOf(String key) => find.descendant(
        of: find.byKey(ValueKey<String>(key)), matching: find.byType(Switch));

    Future<void> tapSwitch(WidgetTester tester, String key) async {
      await tester.ensureVisible(switchOf(key));
      await tester.pumpAndSettle();
      await tester.tap(switchOf(key));
      await tester.pumpAndSettle();
    }

    Future<IntruderDefenseSettings> stored(AppContainer c) async =>
        (await c.intruderDefenseSettings.read()).settings;

    late StaticIntruderEvidenceService fake;
    late AppContainer c;

    setUp(() {
      fake = StaticIntruderEvidenceService();
      c = AppContainer.inMemory(intruderEvidence: fake);
    });

    testWidgets('both switches start OFF and the placeholder is gone',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);
      expect(find.text('Intruder selfie'), findsNothing);
      expect(find.text(SecurityScreen.intruderPhotoTitle), findsOneWidget);
      expect(find.text(SecurityScreen.intruderAlarmTitle), findsOneWidget);
      expect(tester.widget<Switch>(switchOf('intruder_photo_switch')).value,
          isFalse);
      expect(tester.widget<Switch>(switchOf('intruder_alarm_switch')).value,
          isFalse);
      expect(fake.permissionRequests, 0, reason: 'no prompt on open');
    });

    testWidgets('enable photo: verify PIN -> camera permission -> saved',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);
      await tapSwitch(tester, 'intruder_photo_switch');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(fake.permissionRequests, 0, reason: 'not before verification');
      await typePin(tester, _pin);
      // Phase 12 / M3 (R-4): explicit consent between verification and the
      // permission request.
      expect(find.text(SecurityScreen.intruderConsentTitle), findsOneWidget);
      expect(fake.permissionRequests, 0, reason: 'not before consent');
      await tester.tap(find.byKey(const Key('intruder_consent_accept')));
      await tester.pumpAndSettle();
      expect(fake.permissionRequests, 1);
      expect((await stored(c)).evidenceEnabled, isTrue);
      expect(tester.widget<Switch>(switchOf('intruder_photo_switch')).value,
          isTrue);
    });

    testWidgets('cancelled verification: nothing saved, no permission prompt',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);
      await tapSwitch(tester, 'intruder_photo_switch');
      await typePin(tester, '000000'); // wrong, counted normally
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fake.permissionRequests, 0);
      expect((await stored(c)).evidenceEnabled, isFalse);
      expect(
          find.text(SecurityScreen.intruderNotChangedMessage), findsOneWidget);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);
    });

    testWidgets('camera permission denied: photo stays off',
        (WidgetTester tester) async {
      fake.permissionAfterRequest = CameraPermissionState.denied;
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);
      await tapSwitch(tester, 'intruder_photo_switch');
      await typePin(tester, _pin);
      await tester.tap(find.byKey(const Key('intruder_consent_accept')));
      await tester.pumpAndSettle();
      expect(fake.permissionRequests, 1);
      expect((await stored(c)).evidenceEnabled, isFalse);
      expect(find.text(SecurityScreen.intruderCameraDeniedMessage),
          findsOneWidget);
    });

    testWidgets('disabling ALSO requires verification',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings.write(const IntruderDefenseSettings(
          evidenceEnabled: true, alarmEnabled: true));
      await pumpSecurity(tester, c);
      await tapSwitch(tester, 'intruder_alarm_switch');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await stored(c)).alarmEnabled, isTrue);

      await tapSwitch(tester, 'intruder_alarm_switch');
      await typePin(tester, _pin);
      expect((await stored(c)).alarmEnabled, isFalse);
      expect((await stored(c)).evidenceEnabled, isTrue, reason: 'independent');
      expect(fake.alarmStops, 1, reason: 'disabling silences a playing alarm');
    });

    testWidgets('enable alarm after verification; no camera permission asked',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);
      await tapSwitch(tester, 'intruder_alarm_switch');
      await typePin(tester, _pin);
      expect((await stored(c)).alarmEnabled, isTrue);
      expect(fake.permissionRequests, 0);
    });

    testWidgets('without an app credential nothing can be enabled',
        (WidgetTester tester) async {
      await pumpSecurity(tester, c);
      await tapSwitch(tester, 'intruder_photo_switch');
      await tester.pumpAndSettle();
      expect((await stored(c)).evidenceEnabled, isFalse);
      expect(fake.permissionRequests, 0);
    });

    testWidgets('a corrupt settings record disables the switches',
        (WidgetTester tester) async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      await db.setSetting(IntruderDefenseSettingsStore.storageKey, 'corrupt');
      c = AppContainer.inMemory(intruderEvidence: fake, database: db);
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);
      expect(tester.widget<Switch>(switchOf('intruder_photo_switch')).onChanged,
          isNull);
      expect(tester.widget<Switch>(switchOf('intruder_alarm_switch')).onChanged,
          isNull);
    });
  });

  group('static isolation and manifest (source checks)', () {
    String read(String p) => File(p).readAsStringSync();

    test('the M2 Dart code cannot reach enforcement or credential mutation',
        () {
      for (final String f in <String>[
        'lib/security/intruder/intruder_defense_coordinator.dart',
        'lib/security/intruder/intruder_evidence_store.dart',
        'lib/security/intruder/intruder_evidence_service.dart',
        'lib/security/intruder/intruder_defense_settings.dart',
      ]) {
        final String s = read(f);
        for (final String banned in <String>[
          'credential_manager',
          'access_controller',
          'protection/',
          'profiles/',
          'rules/',
          'lock_challenge',
          'overlay',
          'watcher',
          'print(',
          'debugPrint',
          'dart:developer',
          'http',
        ]) {
          expect(s.contains(banned), isFalse, reason: '$f uses $banned');
        }
      }
    });

    // Phase 12 / M3 supersedes the M2 "no UI renders evidence" rule with an
    // allowlist: ONLY the owner-verified viewer decrypts images, only the
    // viewer and Intruder settings touch the evidence store, and neither
    // ever shares, copies, writes files or prints.
    test('evidence images render only in the owner-verified M3 viewer', () {
      const String viewer = 'intruder_evidence_screen.dart';
      const Set<String> storeUsers = <String>{
        viewer,
        'intruder_settings_screen.dart',
      };
      for (final FileSystemEntity e
          in Directory('lib/ui').listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.dart')) {
          final String s = e.readAsStringSync();
          final String name = e.uri.pathSegments.last;
          expect(s.contains('readImage('), name == viewer, reason: e.path);
          if (!storeUsers.contains(name)) {
            expect(s.contains('intruderEvidence.'), isFalse, reason: e.path);
          } else {
            for (final String banned in <String>[
              'Clipboard',
              'Share',
              'File(',
              'print(',
              'debugPrint(',
              'saveToGallery',
              'path_provider',
            ]) {
              expect(s.contains(banned), isFalse, reason: '$name: $banned');
            }
          }
        }
      }
    });

    test('manifest: CAMERA optional; no audio, location or camera FGS', () {
      final String m = read('android/app/src/main/AndroidManifest.xml');
      expect(m, contains('android.permission.CAMERA'));
      expect(
          RegExp(r'android\.hardware\.camera(\.front)?"\s+android:required="false"')
              .allMatches(m)
              .length,
          2);
      for (final String banned in <String>[
        'RECORD_AUDIO',
        'ACCESS_FINE_LOCATION',
        'ACCESS_COARSE_LOCATION',
        'FOREGROUND_SERVICE_CAMERA',
        'FOREGROUND_SERVICE_MICROPHONE',
        'READ_MEDIA_IMAGES',
        'WRITE_EXTERNAL_STORAGE',
        'INTERNET',
      ]) {
        expect(m.contains(banned), isFalse, reason: banned);
      }
    });

    test('Dart and Kotlin agree on the channel name and every method', () {
      const String dir = 'android/app/src/main/kotlin/com/smartapplock/app';
      final String dart = read(
          'lib/services/impl/method_channel_intruder_evidence_service.dart');
      final String kt = read('$dir/IntruderEvidenceChannel.kt');
      final String results =
          read('$dir/IntruderDefensePolicy.kt') + read('$dir/IntruderAlarm.kt');
      expect(
          kt,
          contains(
              'const val CHANNEL = "com.smartapplock.app/intruder_evidence"'));
      expect(dart, contains("'com.smartapplock.app/intruder_evidence'"));
      for (final String m in <String>[
        'cameraPermission',
        'requestCameraPermission',
        'captureStill',
        'startAlarm',
        'stopAlarm',
      ]) {
        expect(dart, contains("'$m'"), reason: m);
        expect(kt, contains('"$m" ->'), reason: m);
      }
      for (final AlarmStartResult r in AlarmStartResult.values) {
        expect(results, contains('"${r.name}"'), reason: r.name);
      }
    });

    test('native: camera/alarm stop with the Activity; no logging, no files',
        () {
      const String dir = 'android/app/src/main/kotlin/com/smartapplock/app';
      final String main = read('$dir/MainActivity.kt');
      final int pause = main.indexOf('override fun onPause()');
      expect(main.indexOf('IntruderEvidenceChannel.onActivityPaused()', pause),
          greaterThan(pause));
      expect(main, contains('IntruderEvidenceChannel.onActivityDestroyed()'));
      final String channel = read('$dir/IntruderEvidenceChannel.kt');
      final String alarm = read('$dir/IntruderAlarm.kt');
      for (final String s in <String>[channel, alarm]) {
        expect(s.contains('Log.'), isFalse);
        expect(s.contains('FileOutputStream'), isFalse);
        expect(s.contains('MediaStore'), isFalse);
        expect(s.contains('setStreamVolume'), isFalse);
        expect(s.contains('setRingerMode'), isFalse);
        expect(s.contains('startForeground'), isFalse);
        expect(s.contains('AudioRecord'), isFalse);
      }
      expect(channel, contains('ProtectionRuntime.activityResumed'));
      expect(channel, contains('isInteractive'));
    });
  });
}
