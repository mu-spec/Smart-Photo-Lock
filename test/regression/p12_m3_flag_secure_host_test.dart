// Phase 12 / M3 commit-readiness gate — Q-M3-2: FLAG_SECURE through the
// REAL lock challenge host and Dart route transitions.
//
// The host clears FLAG_SECURE when its lock loop ends. Before the fix, a
// challenge presented while the app stayed resumed (no lifecycle event)
// covered the evidence detail; after the correct PIN the host cleared the
// flag and the detail rendered the image again with FLAG_SECURE off
// (reproduced: image=1, secure=false). Now a foreign route ends the owner
// session the moment it covers an evidence route, cleanup never pops the
// foreign route, and own-route returns re-run the secure load.
//
// Invariant checked on EVERY frame: evidence pixels are never on screen
// while FLAG_SECURE is off, nor in a frame that STARTED with it off.
//
// SIMULATED: widget tests (SmartAppLockApp + LockChallengeHost over
// AppContainer.inMemory); FLAG_SECURE is the static overlay recorder. The
// Android window flag itself and the recents snapshot are NOT exercised.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/intruder_evidence_screen.dart';
import 'package:smart_app_lock/ui/screens/security/intruder_settings_screen.dart';

import '../support/intruder_fixtures.dart';

const String _pin = '482916';
const String _app = 'com.bank.app';

void main() {
  late AppContainer c;
  int violations = 0;
  int imageFrames = 0;

  StaticOverlayLockService overlay() => c.overlay as StaticOverlayLockService;
  Finder image() => find.byKey(const Key('intruder_evidence_image'));

  /// Samples the invariant on every pumped frame. [secureBefore] is the
  /// flag state when the frame STARTED: the static overlay sets the flag
  /// synchronously, but on a device the flag travels over a platform
  /// channel, so a frame composed before the flag was set is capturable
  /// even if a microtask of that same frame sets it afterwards.
  void sample({bool secureBefore = true}) {
    final bool shown = image().evaluate().isNotEmpty;
    if (shown) imageFrames++;
    if (shown && (!overlay().secureWindow || !secureBefore)) violations++;
  }

  Future<void> frames(WidgetTester tester, [int n = 40]) async {
    for (int i = 0; i < n; i++) {
      final bool before = overlay().secureWindow;
      await tester.pump(const Duration(milliseconds: 16));
      sample(secureBefore: before);
    }
  }

  Future<void> settle(WidgetTester tester) async {
    await frames(tester);
    await tester.pumpAndSettle();
    sample();
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await frames(tester, 16);
    for (final String d in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await frames(tester, 3);
    }
    await settle(tester);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await settle(tester);
    await tester.tap(find.byKey(Key(key)));
    await settle(tester);
  }

  /// Real app + host, owner PIN, a protected app, one stored photo, then
  /// settings -> verified viewer -> detail (image shown, FLAG_SECURE on).
  Future<void> openDetailInRealApp(WidgetTester tester,
      {bool openDetail = true}) async {
    violations = 0;
    imageFrames = 0;
    // Built inside the test body (the host's bootstrap runs in this zone).
    c = AppContainer.inMemory(
      intruderEvidence: StaticIntruderEvidenceService(),
      database: InMemoryLocalDatabase(),
    );
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SmartAppLockApp(container: c));
    await tester.pumpAndSettle();
    await c.auth.enrollPin(_pin);
    await c.protectedApps.add(ProtectedApp(
      packageName: _app,
      label: _app,
      addedAt: DateTime(2026, 10, 22),
      securityLevel: AppSecurityLevel.defaultLevel,
    ));
    await c.protectionBootstrap.synchronize();
    await c.intruderStartup;
    expect(await c.intruderEvidence.save(seq: 1, jpeg: jpegWithMetadata()),
        EvidenceSaveResult.saved);
    tester.state<NavigatorState>(find.byType(Navigator).first).push(
        MaterialPageRoute<void>(
            builder: (_) => IntruderSettingsScreen(container: c)));
    await settle(tester);
    await tapKey(tester, 'intruder_view_evidence');
    await typePin(tester, _pin);
    expect(find.byType(IntruderEvidenceScreen), findsOneWidget);
    expect(c.intruderOwnerSessions.current, isNotNull);
    if (!openDetail) return;
    await tester
        .tap(find.byKey(const ValueKey<String>('intruder_evidence_item_1')));
    await settle(tester);
    expect(image(), findsOneWidget);
    expect(overlay().secureWindow, isTrue);
  }

  void challengeProtectedApp() =>
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_app);

  bool granted() =>
      (c.accessController as DefaultAccessController).sessionFor(_app) != null;

  testWidgets(
      'REGRESSION: a host challenge presented while the app stays resumed '
      'ends the owner session; after the correct PIN the host clears '
      'FLAG_SECURE and the image NEVER renders again', (WidgetTester t) async {
    await openDetailInRealApp(t);
    challengeProtectedApp();
    await settle(t);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(image(), findsNothing);
    expect(c.intruderOwnerSessions.current, isNull,
        reason: 'the foreign cover ended the session immediately');
    expect(overlay().secureWindow, isTrue);

    await typePin(t, _pin);
    expect(granted(), isTrue, reason: 'the host works normally');
    expect(overlay().secureWindow, isFalse,
        reason: 'the host cleared FLAG_SECURE at the end of its loop');
    expect(find.byType(IntruderEvidenceDetailScreen, skipOffstage: false),
        findsNothing);
    expect(
        find.byType(IntruderEvidenceScreen, skipOffstage: false), findsNothing,
        reason: 'evidence routes closed themselves when they surfaced');
    expect(image(), findsNothing);
    expect(violations, 0);
    expect(imageFrames, greaterThan(0), reason: 'the sampler saw the image');
  });

  testWidgets(
      'a host challenge over the evidence LIST alone (no detail open) also '
      'ends the owner session at cover time; after the host PIN the list '
      'closes itself and the evidence needs a fresh verification',
      (WidgetTester t) async {
    await openDetailInRealApp(t, openDetail: false);
    challengeProtectedApp();
    await settle(t);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(c.intruderOwnerSessions.current, isNull,
        reason: 'the foreign cover ended the session immediately');
    await typePin(t, _pin);
    expect(granted(), isTrue);
    expect(
        find.byType(IntruderEvidenceScreen, skipOffstage: false), findsNothing,
        reason: 'the list closed itself when it surfaced');
    expect(find.byType(IntruderSettingsScreen), findsOneWidget);
    expect(c.intruderOwnerSessions.current, isNull);
    // Re-entry requires a fresh owner verification.
    await tapKey(t, 'intruder_view_evidence');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.byType(IntruderEvidenceScreen), findsNothing);
    expect(image(), findsNothing);
    expect(violations, 0);
  });

  testWidgets(
      'session cleanup NEVER pops the host challenge: the cover-triggered '
      'cleanup runs while the challenge is on top and leaves it presented '
      '(host log: exactly one REQUEST, no CLOSED before the PIN)',
      (WidgetTester t) async {
    final List<String> log = <String>[];
    await runZoned(
      () async {
        await openDetailInRealApp(t);
        challengeProtectedApp();
        await settle(t);
        expect(c.intruderOwnerSessions.current, isNull);
        expect(find.byType(PinUnlockScreen), findsOneWidget);
        expect(log.where((String l) => l.contains('CLOSED')), isEmpty,
            reason: 'the challenge route was never popped by the viewer');
        expect(log.where((String l) => l.contains(' REQUEST ')).length, 1,
            reason: 'no re-presentation was needed');
        expect(granted(), isFalse);
        await typePin(t, _pin);
        expect(granted(), isTrue);
        expect(
            log.where((String l) =>
                l.contains('CLOSED reason=authentication-success')),
            hasLength(1));
        expect(find.byType(IntruderEvidenceScreen, skipOffstage: false),
            findsNothing);
        expect(violations, 0);
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
          log.add(line);
        },
      ),
    );
  });

  testWidgets(
      'nested: a host challenge over the OWN delete-confirm dialog; after it '
      'passes (FLAG_SECURE cleared) and the dialog is cancelled, the detail '
      're-arms FLAG_SECURE before any pixel renders', (WidgetTester t) async {
    await openDetailInRealApp(t);
    await tapKey(t, 'intruder_evidence_delete');
    expect(image(), findsNothing, reason: 'hidden while its dialog covers it');
    challengeProtectedApp();
    await settle(t);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await typePin(t, _pin);
    expect(granted(), isTrue);
    expect(overlay().secureWindow, isFalse);
    expect(find.byKey(const Key('intruder_delete_cancel')), findsOneWidget);
    final int callsBefore = overlay().setSecureWindowCalls;
    await t.tap(find.byKey(const Key('intruder_delete_cancel')));
    await settle(t);
    expect(overlay().setSecureWindowCalls, greaterThan(callsBefore));
    expect(overlay().secureWindow, isTrue);
    expect(image(), findsOneWidget,
        reason: 'shown again only after the secure re-load');
    expect(violations, 0,
        reason: 'no frame showed the image with FLAG_SECURE off');
    expect((await c.intruderEvidence.list()).length, 1);
  });

  testWidgets(
      'Q-M3-2 persistence: closing the viewer normally leaves FLAG_SECURE set '
      '(the evidence flow never clears it); the next host loop end clears it',
      (WidgetTester t) async {
    await openDetailInRealApp(t);
    final NavigatorState nav =
        t.state<NavigatorState>(find.byType(Navigator).first);
    nav.pop(); // detail
    await settle(t);
    nav.pop(); // list
    await settle(t);
    expect(
        find.byType(IntruderEvidenceScreen, skipOffstage: false), findsNothing);
    expect(c.intruderOwnerSessions.current, isNull);
    expect(overlay().secureWindow, isTrue,
        reason: 'fail-safe: left set after the viewer closes');
    challengeProtectedApp();
    await settle(t);
    await typePin(t, _pin);
    expect(granted(), isTrue);
    expect(overlay().secureWindow, isFalse,
        reason: 'cleared only by the host when its own loop ends');
    expect(violations, 0);
  });

  testWidgets(
      'lifecycle while the detail is open (inactive -> resumed): the session '
      'ends, the viewer closes, FLAG_SECURE stays set', (WidgetTester t) async {
    await openDetailInRealApp(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(t);
    expect(
        find.byType(IntruderEvidenceScreen, skipOffstage: false), findsNothing);
    expect(image(), findsNothing);
    expect(overlay().secureWindow, isTrue);
    expect(violations, 0);
  });
}
