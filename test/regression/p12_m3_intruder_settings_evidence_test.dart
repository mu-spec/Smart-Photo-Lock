// Phase 12 / M3 — owner-only intruder settings and evidence management.
//
// SIMULATED: widget tests over AppContainer.inMemory with a fake camera/
// alarm platform, the static overlay (FLAG_SECURE recorder) and the static
// screen-state service. Image decoding by the engine is not exercised; the
// presence/absence of the evidence Image widget is.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_service.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_owner_session.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/intruder_evidence_screen.dart';
import 'package:smart_app_lock/ui/screens/security/intruder_settings_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

import '../support/intruder_fixtures.dart';

const String _pin = '482916';

/// A real, decodable 8x8 baseline JPEG (generated with PIL), so the engine
/// really decodes it into the image cache under runAsync.
final Uint8List _realJpeg = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDHooorhPqD/9k=');

FailedAttemptEvent _ev(int seq, int run) => FailedAttemptEvent(
      seq: seq,
      verificationId: 'p:$seq',
      at: DateTime(2026, 10, 22),
      method: FailedAttemptMethod.pin,
      surface: AuthAttemptSurface.protectedAppChallenge,
      consecutiveFailures: run,
      lockoutTriggered: false,
      lockoutStreak: 0,
      counterPersisted: true,
      packageName: 'com.bank.app',
    );

void main() {
  late StaticIntruderEvidenceService fake;
  late InMemoryLocalDatabase db;
  late AppContainer c;

  setUp(() async {
    fake = StaticIntruderEvidenceService();
    db = InMemoryLocalDatabase();
    c = AppContainer.inMemory(intruderEvidence: fake, database: db);
    // Let startup maintenance (real zone) finish before the fake-async test
    // body touches the serialized store (cross-zone hand-off otherwise).
    await c.intruderStartup;
  });

  Future<String> rawEncrypted(String json) async =>
      'enc:v1:${await c.settingsCipher.encryptString(json)}';

  StaticOverlayLockService overlay() => c.overlay as StaticOverlayLockService;

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark,
        onGenerateRoute: AppRouter.onGenerateRoute,
        home: home,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pumpSettings(WidgetTester tester) =>
      pump(tester, IntruderSettingsScreen(container: c));

  Future<void> typePin(WidgetTester tester, String pin) async {
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    for (final String d in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  /// Dismisses the verification route without verifying (back).
  Future<void> cancelVerification(WidgetTester tester) async {
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> seed(List<int> seqs) async {
    for (final int q in seqs) {
      expect(await c.intruderEvidence.save(seq: q, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
    }
  }

  Future<void> openViewer(WidgetTester tester) async {
    await tapKey(tester, 'intruder_view_evidence');
    await typePin(tester, _pin);
    expect(find.byType(IntruderEvidenceScreen), findsOneWidget);
  }

  Future<void> openDetail(WidgetTester tester, int seq) async {
    await tester
        .tap(find.byKey(ValueKey<String>('intruder_evidence_item_$seq')));
    await tester.pumpAndSettle();
    expect(find.byType(IntruderEvidenceDetailScreen), findsOneWidget);
  }

  Finder image() => find.byKey(const Key('intruder_evidence_image'));

  void expectViewerClosed() {
    expect(find.byType(IntruderEvidenceScreen), findsNothing);
    expect(find.byType(IntruderEvidenceDetailScreen), findsNothing);
    expect(image(), findsNothing);
    expect(find.byType(IntruderSettingsScreen), findsOneWidget);
    expect(c.intruderOwnerSessions.current, isNull);
  }

  group('settings screen', () {
    testWidgets(
        'reachable from the Security screen; shows status, permission '
        '(query only) and storage without verification or decryption',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1, 2]);
      await pump(tester, const Scaffold(body: SecurityScreen()));
      await tapKey(tester, 'intruder_settings_row');
      expect(find.byType(IntruderSettingsScreen), findsOneWidget);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(
          find.descendant(
              of: find.byKey(const Key('intruder_status_permission')),
              matching: find.text('Not allowed')),
          findsOneWidget);
      expect(find.textContaining('2 photos'), findsOneWidget);
      expect(fake.permissionRequests, 0, reason: 'never requested here');
      expect(find.text('3 wrong attempts'), findsOneWidget);
    });

    testWidgets(
        'threshold change requires a fresh PIN; cancel leaves it unchanged; '
        'verified change persists and is shown from storage',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await pumpSettings(tester);

      await tapKey(tester, 'intruder_threshold_dropdown');
      await tester.tap(find.text('5 wrong attempts').last);
      await tester.pumpAndSettle();
      await cancelVerification(tester);
      expect((await c.intruderDefenseSettings.read()).health,
          IntruderSettingsHealth.missing,
          reason: 'nothing written without verification');
      expect(find.text(IntruderSettingsText.notChanged), findsOneWidget);
      expect(find.text('3 wrong attempts'), findsOneWidget);

      await tapKey(tester, 'intruder_threshold_dropdown');
      await tester.tap(find.text('5 wrong attempts').last);
      await tester.pumpAndSettle();
      await typePin(tester, _pin);
      expect((await c.intruderDefenseSettings.read()).settings.threshold, 5);
      expect(find.text('5 wrong attempts'), findsOneWidget);
      expect(fake.captureAborts + fake.alarmStops, 0,
          reason: 'threshold-only change never aborts anything');
    });

    testWidgets(
        'a locked-out owner cannot change anything and the lockout is '
        'unchanged (no bypass via settings)', (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      for (int i = 0; i < 5; i++) {
        await c.auth.authenticatePin('000000');
      }
      final CredentialState before = (await c.auth.status()).valueOrNull!;
      expect(before.lockedOutUntil, isNotNull);
      await pumpSettings(tester);
      await tapKey(tester, 'intruder_threshold_dropdown');
      await tester.tap(find.text('7 wrong attempts').last);
      await tester.pumpAndSettle();
      if (find.byType(PinUnlockScreen).evaluate().isNotEmpty) {
        await typePin(tester, _pin); // correct PIN during lockout: refused
        if (find.byType(PinUnlockScreen).evaluate().isNotEmpty) {
          await cancelVerification(tester);
        }
      }
      expect((await c.intruderDefenseSettings.read()).settings.threshold, 3);
      final CredentialState after = (await c.auth.status()).valueOrNull!;
      expect(after.lockedOutUntil, before.lockedOutUntil);
      expect(after.lockoutStreak, before.lockoutStreak);
    });

    testWidgets('newer-schema evidence: shown as unsupported, no view/clear',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await c.intruderEvidence.save(seq: 1, jpeg: jpegWithMetadata());
      // Simulate a newer app version's index.
      final String newer = await rawEncrypted('{"v":2,"items":[]}');
      await db.setSetting(IntruderEvidenceStore.indexKey, newer);
      await pumpSettings(tester);
      expect(find.text(IntruderEvidenceText.unsupported), findsOneWidget);
      final DsButtonProbe view =
          DsButtonProbe(tester, 'intruder_view_evidence');
      final DsButtonProbe clear = DsButtonProbe(tester, 'intruder_clear_all');
      expect(view.enabled, isFalse);
      expect(clear.enabled, isFalse);
      expect(await db.getSetting(IntruderEvidenceStore.indexKey), newer);
    });
  });

  group('evidence viewer access', () {
    testWidgets('unverified (cancel): nothing is shown, no session',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await tapKey(tester, 'intruder_view_evidence');
      await cancelVerification(tester);
      expect(find.byType(IntruderEvidenceScreen), findsNothing);
      expect(find.byKey(const ValueKey<String>('intruder_evidence_item_1')),
          findsNothing);
      expect(c.intruderOwnerSessions.current, isNull);
      expect(find.text(IntruderEvidenceText.notVerified), findsOneWidget);
    });

    testWidgets(
        'verified: metadata list (no image), FLAG_SECURE set; detail shows '
        'the image; FLAG_SECURE is NOT cleared on exit',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1, 2]);
      await pumpSettings(tester);
      await openViewer(tester);
      expect(overlay().secureWindow, isTrue);
      expect(find.byKey(const ValueKey<String>('intruder_evidence_item_1')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('intruder_evidence_item_2')),
          findsOneWidget);
      expect(find.byType(Image), findsNothing, reason: 'no thumbnails');

      await openDetail(tester, 2);
      expect(image(), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator).last).pop();
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator).last).pop();
      await tester.pumpAndSettle();
      expectViewerClosed();
      expect(overlay().secureWindow, isTrue, reason: 'fail-safe: not cleared');
    });

    testWidgets('FLAG_SECURE failure: the image is refused (fail closed)',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      overlay().secureWindowFails = true;
      await pumpSettings(tester);
      await openViewer(tester);
      await openDetail(tester, 1);
      expect(image(), findsNothing);
      expect(find.text(IntruderEvidenceText.secureFailed), findsOneWidget);
    });

    testWidgets('damaged evidence shows "unavailable" and is still deletable',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await db.setSetting(IntruderEvidenceStore.blobKey(1), 'enc:v1:garbage');
      await pumpSettings(tester);
      await openViewer(tester);
      await openDetail(tester, 1);
      expect(image(), findsNothing);
      expect(find.text(IntruderEvidenceText.unavailable), findsOneWidget);
      await tapKey(tester, 'intruder_evidence_delete');
      await tapKey(tester, 'intruder_delete_confirm');
      await typePin(tester, _pin);
      expect(await c.intruderEvidence.list(), isEmpty);
    });

    testWidgets('expired items are removed before the owner list renders',
        (WidgetTester tester) async {
      // Save the recent item first, then the 40-day-old one, so the
      // seeding store's own retention (relative to its clock) keeps both.
      DateTime t = DateTime.now().subtract(const Duration(days: 1));
      final IntruderEvidenceStore aged =
          IntruderEvidenceStore(db, c.settingsCipher, now: () => t);
      await aged.save(seq: 2, jpeg: jpegWithMetadata());
      t = DateTime.now().subtract(const Duration(days: 40));
      await aged.save(seq: 1, jpeg: jpegWithMetadata());
      expect((await c.intruderEvidence.list()).length, 2);
      await c.auth.enrollPin(_pin);
      await pumpSettings(tester);
      await openViewer(tester);
      final List<EvidenceItem> left = await c.intruderEvidence.list();
      for (final EvidenceItem e in left) {
        expect(
            DateTime.now().difference(e.at) <
                IntruderEvidenceStore.defaultRetention,
            isTrue);
        expect(find.byKey(ValueKey<String>('intruder_evidence_item_${e.seq}')),
            findsOneWidget);
      }
      expect(find.byKey(const ValueKey<String>('intruder_evidence_item_1')),
          findsNothing,
          reason: 'item 1 is older than 30 days and must not be listed');
    });
  });

  test('container startup sweeps orphans, then enforces retention', () async {
    final InMemoryLocalDatabase shared = InMemoryLocalDatabase();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer first =
        AppContainer.inMemory(database: shared, secretStore: secrets);
    DateTime t = DateTime.now().subtract(const Duration(days: 1));
    final IntruderEvidenceStore seeder =
        IntruderEvidenceStore(shared, first.settingsCipher, now: () => t);
    await seeder.save(seq: 2, jpeg: jpegWithMetadata());
    t = DateTime.now().subtract(const Duration(days: 40));
    await seeder.save(seq: 1, jpeg: jpegWithMetadata());
    expect((await seeder.list()).length, 2);

    final AppContainer restarted =
        AppContainer.inMemory(database: shared, secretStore: secrets);
    await restarted.intruderStartup;
    final List<EvidenceItem> left = await restarted.intruderEvidence.list();
    expect(left.map((EvidenceItem e) => e.seq), <int>[2]);
    expect(await shared.getSetting(IntruderEvidenceStore.blobKey(1)), isNull);
  });

  group('session invalidation (privacy)', () {
    for (final AppLifecycleState state in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      testWidgets('lifecycle ${state.name} closes the detail and the list',
          (WidgetTester tester) async {
        await c.auth.enrollPin(_pin);
        await seed(<int>[1]);
        await pumpSettings(tester);
        await openViewer(tester);
        await openDetail(tester, 1);
        expect(image(), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pumpAndSettle();
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expectViewerClosed();
      });
    }

    testWidgets('screen-off closes the viewer', (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openViewer(tester);
      await openDetail(tester, 1);
      (c.screenState as StaticScreenStateService).emitScreenOff();
      await tester.pumpAndSettle();
      expectViewerClosed();
    });

    testWidgets('absolute expiry closes an idle viewer (UI timer)',
        (WidgetTester tester) async {
      c.intruderOwnerSessions =
          IntruderOwnerSessionGate(maxAge: const Duration(seconds: 30));
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openViewer(tester);
      await openDetail(tester, 1);
      // Opening the viewer and detail took ~1-2 s of fake time; still
      // well inside the 30 s lifetime.
      await tester.pump(const Duration(seconds: 20));
      expect(image(), findsOneWidget);
      expect(c.intruderOwnerSessions.current, isNotNull);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expectViewerClosed();
    });

    testWidgets(
        'expiry while the image is loading: never shown (post-await check)',
        (WidgetTester tester) async {
      DateTime t = DateTime.now();
      c.intruderOwnerSessions = IntruderOwnerSessionGate(now: () => t);
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openViewer(tester);
      // Jump the session clock past maxAge, then open the detail: the
      // per-step re-check refuses before/after the decrypt.
      t = t.add(IntruderOwnerSessionGate.defaultMaxAge);
      await tester
          .tap(find.byKey(const ValueKey<String>('intruder_evidence_item_1')));
      await tester.pumpAndSettle();
      expect(image(), findsNothing);
      expectViewerClosed();
    });

    testWidgets(
        'credential state change (lockout) while open: the next step '
        're-checks and closes the viewer', (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openViewer(tester);
      for (int i = 0; i < 5; i++) {
        await c.auth.authenticatePin('000000');
      }
      await openDetailOrClosed(tester, 1);
      expect(image(), findsNothing);
      expectViewerClosed();
    });
  });

  testWidgets(
      'the DECODED evidence image is evicted from the image cache when the '
      'session ends', (WidgetTester tester) async {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    cache
      ..clear()
      ..clearLiveImages();
    await c.auth.enrollPin(_pin);
    // The pure-Dart AES-GCM yields to the event loop on larger inputs:
    // seed under real async (fake time is not advancing before pumpWidget).
    expect(
        await tester
            .runAsync(() => c.intruderEvidence.save(seq: 1, jpeg: _realJpeg)),
        EvidenceSaveResult.saved);
    await pumpSettings(tester);
    await openViewer(tester);
    await openDetail(tester, 1);
    expect(image(), findsOneWidget);
    await tester.runAsync(() async {
      for (int i = 0; i < 200 && cache.currentSize == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(cache.currentSize + cache.liveImageCount, greaterThan(0),
        reason: 'precondition: the engine decoded the evidence into the cache');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expectViewerClosed();
    expect(
        cache.currentSize + cache.liveImageCount + cache.pendingImageCount, 0,
        reason: 'no decoded evidence pixels remain cached');
  });

  testWidgets(
      'credential state change while the detail is open: returning to the '
      'list re-checks and closes the viewer (list-level re-check)',
      (WidgetTester tester) async {
    await c.auth.enrollPin(_pin);
    await seed(<int>[1]);
    await pumpSettings(tester);
    await openViewer(tester);
    await openDetail(tester, 1);
    expect(image(), findsOneWidget);
    for (int i = 0; i < 5; i++) {
      await c.auth.authenticatePin('000000');
    }
    // Back from the detail (its own load already ran): the list reloads
    // and must re-check the credential before showing metadata again.
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();
    expectViewerClosed();
    expect(find.byKey(const ValueKey<String>('intruder_evidence_item_1')),
        findsNothing);
  });

  group('owner deletion', () {
    testWidgets(
        'delete-one needs its own fresh verification; cancel keeps it; '
        'verified delete removes only it and keeps history/counters',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1, 2]);
      await c.auth.authenticatePin('000000'); // one failure on record
      await pumpSettings(tester);
      await openViewer(tester);
      final int failedBefore =
          (await c.auth.status()).valueOrNull!.failedAttempts;
      final Object? logBefore =
          (await c.intruderMonitor.snapshot())?.events.length;

      await openDetail(tester, 2);
      await tapKey(tester, 'intruder_evidence_delete');
      await tapKey(tester, 'intruder_delete_confirm');
      await cancelVerification(tester);
      expect((await c.intruderEvidence.list()).length, 2);
      expect(find.text(IntruderEvidenceText.notDeleted), findsOneWidget);

      await tapKey(tester, 'intruder_evidence_delete');
      await tapKey(tester, 'intruder_delete_confirm');
      await typePin(tester, _pin);
      expect((await c.intruderEvidence.list()).map((EvidenceItem e) => e.seq),
          <int>[1]);
      expect(find.byType(IntruderEvidenceDetailScreen), findsNothing);
      expect(find.byKey(const ValueKey<String>('intruder_evidence_item_2')),
          findsNothing);
      expect(find.byKey(const ValueKey<String>('intruder_evidence_item_1')),
          findsOneWidget);
      expect((await c.intruderMonitor.snapshot())?.events.length, logBefore,
          reason: 'M1 event history untouched');
      expect(failedBefore, 0, reason: 'opening the viewer was a normal auth');
      expect(await c.intruderEvidence.save(seq: 2, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.superseded);
    });

    testWidgets('confirm dialog cancel: no verification, nothing deleted',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openViewer(tester);
      await openDetail(tester, 1);
      await tapKey(tester, 'intruder_evidence_delete');
      expect(image(), findsNothing, reason: 'hidden while a dialog covers it');
      await tapKey(tester, 'intruder_delete_cancel');
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect((await c.intruderEvidence.list()).length, 1);
      expect(image(), findsOneWidget);
    });

    testWidgets(
        'clear-all from settings: confirm + fresh PIN; settings, M1 log and '
        'auth state unchanged', (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings.write(const IntruderDefenseSettings(
          evidenceEnabled: true, alarmEnabled: true, threshold: 4));
      await seed(<int>[1, 2, 3]);
      await pumpSettings(tester);

      await tapKey(tester, 'intruder_clear_all');
      await tapKey(tester, 'intruder_clear_all_confirm');
      await cancelVerification(tester);
      expect((await c.intruderEvidence.list()).length, 3);

      await tapKey(tester, 'intruder_clear_all');
      await tapKey(tester, 'intruder_clear_all_confirm');
      await typePin(tester, _pin);
      expect(await c.intruderEvidence.list(), isEmpty);
      expect(find.text(IntruderEvidenceText.clearedAll), findsOneWidget);
      expect(
          (await c.intruderDefenseSettings.read()).settings,
          const IntruderDefenseSettings(
              evidenceEnabled: true, alarmEnabled: true, threshold: 4));
      expect(fake.alarmStops, 0, reason: 'clear-all does not touch the alarm');
      expect(fake.captureAborts, 1, reason: 'pending capture aborted');
    });

    testWidgets(
        'clear-all while a capture is in flight: the late result is never '
        'saved (no resurrection)', (WidgetTester tester) async {
      final GatedEvidenceService gated = GatedEvidenceService()
        ..permission = CameraPermissionState.granted;
      c = AppContainer.inMemory(intruderEvidence: gated, database: db);
      await tester.runAsync(() => c.intruderStartup);
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings.write(
          const IntruderDefenseSettings(evidenceEnabled: true, threshold: 1));
      await seed(<int>[1]);
      gated.gate = Completer<CaptureResult>();
      c.intruderDefense.onFailedAttemptRecorded(_ev(2, 1));
      await tester.pump();
      await pumpSettings(tester);
      expect(gated.captures, 1);

      await tapKey(tester, 'intruder_clear_all');
      await tapKey(tester, 'intruder_clear_all_confirm');
      await typePin(tester, _pin);
      expect(gated.ops, contains('abort'));

      gated.gate!.complete(CaptureSucceeded(jpegWithMetadata()));
      await c.intruderDefense.idle();
      await tester.pumpAndSettle();
      expect(await c.intruderEvidence.list(), isEmpty);
      expect(await c.intruderEvidence.save(seq: 2, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.superseded);
    });

    testWidgets('clear-all from the viewer requires a fresh PIN too',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1, 2]);
      await pumpSettings(tester);
      await openViewer(tester);
      await tapKey(tester, 'intruder_evidence_clear_all');
      await tapKey(tester, 'intruder_clear_all_confirm');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await typePin(tester, _pin);
      expect(await c.intruderEvidence.list(), isEmpty);
      expect(find.text(IntruderEvidenceText.empty), findsOneWidget);
    });

    testWidgets(
        'session ends during the delete verification: the verification is '
        'torn down and nothing is deleted', (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openViewer(tester);
      await openDetail(tester, 1);
      await tapKey(tester, 'intruder_evidence_delete');
      await tapKey(tester, 'intruder_delete_confirm');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      (c.screenState as StaticScreenStateService).emitScreenOff();
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsNothing);
      expectViewerClosed();
      expect((await c.intruderEvidence.list()).length, 1);
    });
  });

  group('consent (R-4) on the Security screen', () {
    Finder photoSwitch() => find.descendant(
        of: find.byKey(const ValueKey<String>('intruder_photo_switch')),
        matching: find.byType(Switch));

    Future<void> tapPhoto(WidgetTester tester) async {
      await tester.ensureVisible(photoSwitch());
      await tester.pumpAndSettle();
      await tester.tap(photoSwitch());
      await tester.pumpAndSettle();
    }

    testWidgets(
        'enabling shows consent AFTER verification and BEFORE any permission '
        'request; declining requests and writes nothing',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await pump(tester, const Scaffold(body: SecurityScreen()));
      await tapPhoto(tester);
      expect(find.text(SecurityScreen.intruderConsentTitle), findsNothing,
          reason: 'verification comes first');
      await typePin(tester, _pin);
      expect(find.text(SecurityScreen.intruderConsentTitle), findsOneWidget);
      expect(fake.permissionRequests, 0);
      await tester.tap(find.byKey(const Key('intruder_consent_decline')));
      await tester.pumpAndSettle();
      expect(fake.permissionRequests, 0);
      expect((await c.intruderDefenseSettings.read()).health,
          IntruderSettingsHealth.missing);
      expect(tester.widget<Switch>(photoSwitch()).value, isFalse);
    });

    testWidgets('accepting consent requests permission, then saves',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await pump(tester, const Scaffold(body: SecurityScreen()));
      await tapPhoto(tester);
      await typePin(tester, _pin);
      await tester.tap(find.byKey(const Key('intruder_consent_accept')));
      await tester.pumpAndSettle();
      expect(fake.permissionRequests, 1);
      expect((await c.intruderDefenseSettings.read()).settings.evidenceEnabled,
          isTrue);
    });

    testWidgets('disabling keeps existing evidence (R-6) and aborts capture',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings
          .write(const IntruderDefenseSettings(evidenceEnabled: true));
      await seed(<int>[1]);
      await pump(tester, const Scaffold(body: SecurityScreen()));
      await tapPhoto(tester);
      await typePin(tester, _pin);
      expect(find.text(SecurityScreen.intruderConsentTitle), findsNothing);
      expect((await c.intruderDefenseSettings.read()).settings.evidenceEnabled,
          isFalse);
      expect((await c.intruderEvidence.list()).length, 1);
      expect(fake.captureAborts, 1);
    });
  });
}

/// Helper used where the next step may already close the viewer.
Future<void> openDetailOrClosed(WidgetTester tester, int seq) async {
  final Finder item =
      find.byKey(ValueKey<String>('intruder_evidence_item_$seq'));
  if (item.evaluate().isNotEmpty) {
    await tester.tap(item);
    await tester.pumpAndSettle();
  }
}

class DsButtonProbe {
  DsButtonProbe(this.tester, this.key);

  final WidgetTester tester;
  final String key;

  bool get enabled {
    final Widget w = tester.widget(find.byKey(Key(key)));
    // DsButton exposes onPressed.
    return (w as dynamic).onPressed != null;
  }
}
