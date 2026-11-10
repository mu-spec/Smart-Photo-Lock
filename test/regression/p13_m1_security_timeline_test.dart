// Phase 13 / Milestone 1 — Security timeline UI, owner session, FLAG_SECURE
// lifecycle and journal failure isolation through the REAL app and the REAL
// lock challenge host.
//
// Invariant sampled on EVERY pumped frame: no timeline history is on
// screen while FLAG_SECURE is off, nor in a frame that STARTED with it off.
//
// SIMULATED: widget tests (SmartAppLockApp + LockChallengeHost over
// AppContainer.inMemory). FLAG_SECURE is the static overlay recorder; the
// Android window flag and recents snapshot are NOT exercised (device QA).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_owner_session.dart';
import 'package:smart_app_lock/security/timeline/security_event_journal.dart';
import 'package:smart_app_lock/security/timeline/security_event_journal_store.dart';
import 'package:smart_app_lock/security/timeline/security_journal_event.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_timeline_screen.dart';

import '../support/credential_change_grant.dart';

const String _pin = '482916';
const String _app = 'com.bank.app';

/// Every journal read/write throws (journal storage completely broken).
class _JournalFaultDb extends InMemoryLocalDatabase {
  int journalCalls = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (key.startsWith(SecurityEventJournalStore.storageKey)) {
      journalCalls++;
      throw StateError('journal read fault');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (key.startsWith(SecurityEventJournalStore.storageKey)) {
      journalCalls++;
      throw StateError('journal write fault');
    }
    return super.setSetting(key, value);
  }
}

void main() {
  late AppContainer c;
  int violations = 0;
  int historyFrames = 0;

  StaticOverlayLockService overlay() => c.overlay as StaticOverlayLockService;

  Finder history() => find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>)
                .value
                .startsWith('security_timeline_entry_'),
        skipOffstage: false,
      );

  void sample({bool secureBefore = true}) {
    final bool shown = history().evaluate().isNotEmpty;
    if (shown) historyFrames++;
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

  NavigatorState nav(WidgetTester t) =>
      t.state<NavigatorState>(find.byType(Navigator).first);

  /// Real app (built inside the test body), owner PIN, a protected app.
  Future<void> boot(
    WidgetTester tester, {
    InMemoryLocalDatabase? database,
    int wrongBefore = 2,
  }) async {
    violations = 0;
    historyFrames = 0;
    c = AppContainer.inMemory(
      intruderEvidence: StaticIntruderEvidenceService(),
      database: database ?? InMemoryLocalDatabase(),
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
    await c.securityJournalStartup;
    for (int i = 0; i < wrongBefore; i++) {
      await c.auth.authenticatePin('000000');
    }
    await c.intruderMonitor.idle();
    await tester.pumpAndSettle();
  }

  /// Pushes a launcher route and starts [openSecurityTimeline] from it.
  Future<Future<bool>> launch(WidgetTester tester) async {
    late BuildContext launcher;
    nav(tester).push(MaterialPageRoute<void>(
      builder: (BuildContext ctx) {
        launcher = ctx;
        return const Scaffold(body: Text('launcher'));
      },
    ));
    await settle(tester);
    final Future<bool> opened = openSecurityTimeline(launcher, c);
    await settle(tester);
    return opened;
  }

  Future<void> openTimeline(WidgetTester tester) async {
    unawaited(await launch(tester));
    await typePin(tester, _pin);
    expect(find.byType(SecurityTimelineScreen), findsOneWidget);
    expect(c.securityTimelineSessions.current, isNotNull);
  }

  void challengeProtectedApp() =>
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_app);

  bool granted() =>
      (c.accessController as DefaultAccessController).sessionFor(_app) != null;

  void expectClosed() {
    expect(find.byType(SecurityTimelineScreen), findsNothing);
    expect(history(), findsNothing);
    expect(c.securityTimelineSessions.current, isNull);
  }

  testWidgets(
      'Security tab shows the Security timeline row and it requires '
      'fresh verification', (WidgetTester t) async {
    await boot(t);
    await t.tap(find.byKey(const Key('nav_security')));
    await settle(t);
    final Finder row =
        find.byKey(const ValueKey<String>('security_timeline_row'));
    await t.scrollUntilVisible(row, 200,
        scrollable: find.byType(Scrollable).first);
    await settle(t);
    await t.tap(row);
    await settle(t);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.byType(SecurityTimelineScreen), findsNothing);
    expect(overlay().secureWindow, isFalse,
        reason: 'nothing secure is needed before verification');
    await typePin(t, _pin);
    expect(find.byType(SecurityTimelineScreen), findsOneWidget);
    expect(history(), findsWidgets);
    expect(violations, 0);
  });

  testWidgets('verification cancelled -> nothing opens, no session',
      (WidgetTester t) async {
    await boot(t);
    final Future<bool> opened = await launch(t);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    nav(t).pop();
    await settle(t);
    expect(await opened, isFalse);
    expectClosed();
    expect(historyFrames, 0);
  });

  testWidgets(
      'verified: FLAG_SECURE first, then failed unlocks + journal '
      'marker, newest first, footer, no empty claim (A1-6)',
      (WidgetTester t) async {
    await boot(t);
    await openTimeline(t);
    expect(overlay().secureWindow, isTrue);
    expect(find.byKey(const Key('security_timeline_entry_failedAttempts_0')),
        findsOneWidget);
    expect(find.byKey(const Key('security_timeline_entry_failedAttempts_1')),
        findsOneWidget);
    expect(find.byKey(const Key('security_timeline_entry_journal_0')),
        findsOneWidget);
    expect(find.text('Security journal first used'), findsOneWidget);
    final Finder marker =
        find.byKey(const Key('security_timeline_entry_journal_0'));
    expect(
        find.descendant(
            of: marker,
            matching: find.textContaining(
                'No journal events were recorded before this time.')),
        findsOneWidget);
    // A-1: the lazily created marker is a FIRST-USE time; it must never be
    // presented as an install / app-start time.
    expect(
        find.descendant(
            of: marker,
            matching: find.textContaining(RegExp(
                r'install|app start|launch|started',
                caseSensitive: false))),
        findsNothing);
    expect(find.byKey(const Key('security_timeline_footer')), findsOneWidget);
    expect(find.byKey(const Key('security_timeline_empty')), findsNothing);
    final double y1 = t
        .getTopLeft(
            find.byKey(const Key('security_timeline_entry_failedAttempts_1')))
        .dy;
    final double y0 = t
        .getTopLeft(
            find.byKey(const Key('security_timeline_entry_failedAttempts_0')))
        .dy;
    expect(y1, lessThan(y0), reason: 'newest first');
    expect(find.byType(SelectableText), findsNothing);
    expect(violations, 0);
    expect(historyFrames, greaterThan(0));
  });

  testWidgets(
      'FLAG_SECURE failure -> fails closed, history never read or '
      'shown', (WidgetTester t) async {
    await boot(t);
    overlay().secureWindowFails = true;
    await openTimeline(t);
    expect(find.byKey(const Key('security_timeline_secure_failed')),
        findsOneWidget);
    expect(history(), findsNothing);
    expect(find.byKey(const Key('security_timeline_footer')), findsNothing);
    expect(historyFrames, 0);
  });

  testWidgets(
      'FLAG_SECURE failure -> no sensitive read at all: the lazily created '
      'journal row is never created (the reader never ran)',
      (WidgetTester t) async {
    final InMemoryLocalDatabase db = InMemoryLocalDatabase();
    await boot(t, database: db);
    expect(await db.getSetting(SecurityEventJournalStore.storageKey), isNull);
    overlay().secureWindowFails = true;
    await openTimeline(t);
    expect(find.byKey(const Key('security_timeline_secure_failed')),
        findsOneWidget);
    await c.securityJournal.idle();
    expect(await db.getSetting(SecurityEventJournalStore.storageKey), isNull);
    expect(historyFrames, 0);
  });

  testWidgets(
      'primary method switched (CR-3 grant) during an open session -> '
      '"Show older" re-check ends the session', (WidgetTester t) async {
    await boot(t, wrongBefore: 0);
    for (int i = 0; i < 60; i++) {
      c.securityJournal.record(SecurityJournalEventType.journalRecovered);
      if (i % 30 == 29) await c.securityJournal.idle();
    }
    await c.securityJournal.idle();
    await openTimeline(t);
    final Finder older = find.byKey(const Key('security_timeline_show_older'));
    await t.scrollUntilVisible(older, 400,
        scrollable: find.byType(Scrollable).last);
    await settle(t);
    await c.auth.enrollPattern(const <int>[1, 2, 3, 6],
        authorization: await grantWithPin(c.auth, _pin));
    expect((await c.auth.status()).valueOrNull!.primary, AuthType.pattern);
    await t.tap(older);
    await settle(t);
    expectClosed();
  });

  testWidgets('app paused -> session ends, history dropped, timeline closes',
      (WidgetTester t) async {
    await boot(t);
    await openTimeline(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(t);
    expectClosed();
    expect(find.text(SecurityTimelineText.sessionEnded), findsOneWidget);
    expect(violations, 0);
  });

  testWidgets('screen off -> session ends and timeline closes',
      (WidgetTester t) async {
    await boot(t);
    await openTimeline(t);
    (c.screenState as StaticScreenStateService).emitScreenOff();
    await settle(t);
    expectClosed();
  });

  testWidgets('absolute expiry (2 min) closes the timeline',
      (WidgetTester t) async {
    await boot(t);
    await openTimeline(t);
    await t.pump(const Duration(minutes: 2, seconds: 1));
    await settle(t);
    expectClosed();
  });

  testWidgets('credential removed -> "Show older" re-check ends the session',
      (WidgetTester t) async {
    await boot(t);
    for (int i = 0; i < 60; i++) {
      c.securityJournal.record(SecurityJournalEventType.journalRecovered);
      if (i % 30 == 29) await c.securityJournal.idle();
    }
    await c.securityJournal.idle();
    await openTimeline(t);
    final Finder older = find.byKey(const Key('security_timeline_show_older'));
    await t.scrollUntilVisible(older, 400,
        scrollable: find.byType(Scrollable).last);
    await settle(t);
    expect(history().evaluate().length, lessThanOrEqualTo(50));
    await c.auth.clearAll();
    await t.tap(older);
    await settle(t);
    expectClosed();
  });

  testWidgets('"Show older" pages the next 50 while authorized',
      (WidgetTester t) async {
    await boot(t, wrongBefore: 0);
    for (int i = 0; i < 60; i++) {
      c.securityJournal.record(SecurityJournalEventType.journalRecovered);
      if (i % 30 == 29) await c.securityJournal.idle();
    }
    await c.securityJournal.idle();
    await openTimeline(t);
    final Finder older = find.byKey(const Key('security_timeline_show_older'));
    await t.scrollUntilVisible(older, 400,
        scrollable: find.byType(Scrollable).last);
    await settle(t);
    await t.tap(older);
    await settle(t);
    expect(older, findsNothing);
    // journal seq 0 (the start marker) is the oldest row: reachable now.
    final Finder oldest =
        find.byKey(const Key('security_timeline_entry_journal_0'));
    await t.scrollUntilVisible(oldest, 400,
        scrollable: find.byType(Scrollable).last);
    expect(oldest, findsOneWidget);
    expect(violations, 0);
  });

  testWidgets(
      'REGRESSION (Q-P13-2): a host challenge presented while the '
      'app stays resumed ends the session; after the correct PIN the host '
      'clears FLAG_SECURE and history NEVER renders again',
      (WidgetTester t) async {
    await boot(t);
    await openTimeline(t);
    challengeProtectedApp();
    await settle(t);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(c.securityTimelineSessions.current, isNull,
        reason: 'foreign cover invalidates immediately');
    expect(history(), findsNothing, reason: 'history dropped while covered');
    final int before = historyFrames;
    await typePin(t, _pin);
    await settle(t);
    expect(granted(), isTrue);
    expect(historyFrames, before, reason: 'never shown again');
    expectClosed();
    expect(violations, 0);
  });

  testWidgets(
      'a foreign route covering the timeline is never popped by '
      'session cleanup', (WidgetTester t) async {
    await boot(t);
    await openTimeline(t);
    nav(t).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/foreign'),
      builder: (_) => const Scaffold(body: Text('foreign')),
    ));
    await settle(t);
    expect(c.securityTimelineSessions.current, isNull);
    expect(find.text('foreign'), findsOneWidget);
    nav(t).pop();
    await settle(t);
    expectClosed();
    expect(find.text('launcher'), findsOneWidget);
  });

  testWidgets(
      'unreadable failure history is an explicit unavailable row, '
      'never "No security events" (C)', (WidgetTester t) async {
    final InMemoryLocalDatabase db = InMemoryLocalDatabase();
    await boot(t, database: db, wrongBefore: 0);
    // Newer-schema failure log written with the app's own cipher before
    // the monitor first loads it.
    final String json = jsonEncode(<String, Object?>{
      'schema': 'sal.intruder_log',
      'v': 5,
      'nextSeq': 1,
      'events': <Object?>[],
    });
    await db.setSetting(IntruderFailureLogStore.storageKey,
        'enc:v1:${await c.settingsCipher.encryptString(json)}');
    await openTimeline(t);
    expect(
        find.byKey(const Key('security_timeline_unavailable_failedAttempts')),
        findsOneWidget);
    expect(find.byKey(const Key('security_timeline_empty')), findsNothing);
  });

  testWidgets('damaged earlier journal + discarded failures are disclosed (D)',
      (WidgetTester t) async {
    final InMemoryLocalDatabase db = InMemoryLocalDatabase();
    await db.setSetting(SecurityEventJournalStore.storageKey, 'garbage');
    await boot(t, database: db, wrongBefore: 0);
    await openTimeline(t);
    expect(find.byKey(const Key('security_timeline_damaged_journal')),
        findsOneWidget);
    expect(find.text('Security journal was damaged and reset'), findsOneWidget);
    expect(find.byKey(const Key('security_timeline_footer')), findsOneWidget);
  });

  testWidgets(
      'journal storage completely broken: host challenge, failure '
      'counting, lockout and unlock are unaffected; timeline shows the '
      'journal as unavailable (A1-5, corrections A/B)', (WidgetTester t) async {
    final _JournalFaultDb db = _JournalFaultDb();
    await boot(t, database: db, wrongBefore: 0);
    expect(c.securityJournal.health, isNot(SecurityJournalHealth.ok));
    // Producer path under a broken journal: never throws, never blocks.
    for (int i = 0; i < 100; i++) {
      recordSecurityEventSafely(
          c.securityJournal, SecurityJournalEventType.journalRecovered);
    }
    challengeProtectedApp();
    await settle(t);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await typePin(t, '000000');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(granted(), isFalse);
    await c.intruderMonitor.idle();
    expect((await c.intruderMonitor.snapshot())!.events.length, 1);
    await typePin(t, _pin);
    expect(granted(), isTrue);
    expect(db.journalCalls, greaterThan(0));
    // Lockout still engages with the journal broken.
    for (int i = 0; i < 5; i++) {
      await c.auth.authenticatePin('000000');
    }
    expect((await c.auth.status()).valueOrNull!.lockedOutUntil, isNotNull);
  });

  testWidgets(
      'journal broken: timeline still opens with an explicit '
      'unavailable journal row', (WidgetTester t) async {
    final _JournalFaultDb db = _JournalFaultDb();
    await boot(t, database: db);
    await openTimeline(t);
    expect(find.byKey(const Key('security_timeline_unavailable_journal')),
        findsOneWidget);
    expect(find.byKey(const Key('security_timeline_entry_failedAttempts_0')),
        findsOneWidget);
    expect(find.byKey(const Key('security_timeline_empty')), findsNothing);
    expect(violations, 0);
  });

  Future<void> pushWithSession(WidgetTester t, AuthType method) async {
    final IntruderOwnerSession session =
        c.securityTimelineSessions.begin(method);
    nav(t).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: securityTimelineRouteName),
      builder: (_) => SecurityTimelineScreen(container: c, session: session),
    ));
    await settle(t);
  }

  testWidgets(
      'credential removed after verification -> load-time re-check '
      'ends the session before anything is read', (WidgetTester t) async {
    await boot(t);
    await c.auth.clearAll();
    await pushWithSession(t, AuthType.pin);
    expectClosed();
    expect(historyFrames, 0);
  });

  testWidgets(
      'verified method no longer the primary -> load-time re-check '
      'ends the session', (WidgetTester t) async {
    await boot(t);
    await pushWithSession(t, AuthType.pattern);
    expectClosed();
    expect(historyFrames, 0);
  });

  testWidgets('timeline session is separate from evidence sessions',
      (WidgetTester t) async {
    await boot(t);
    await openTimeline(t);
    expect(c.intruderOwnerSessions.current, isNull,
        reason: 'opening the timeline never grants evidence access');
  });
}
