// Phase 12 / M3 commit-readiness gate — Q-M3-3: credential replacement,
// session expiry and authorization freshness at EVERY evidence mutation
// commit point.
//
// Commit points (see M3_SECURITY_REVIEW.md §2a):
//   delete-one (viewer)  : own fresh verification -> post-verification status
//                          re-check -> session valid AND same credential type
//                          -> store commit gated by stillValid (session).
//   clear-all (viewer)   : same as delete-one.
//   clear-all (settings) : own fresh verification + status re-check.
//   threshold / photo / alarm : own fresh verification + status re-check.
// The credential replacement below is done programmatically: the app UI
// cannot reach a credential change while an evidence route is open (Q-M3-3
// structural invalidation); these tests prove the commit points still
// refuse if it happened anyway.
//
// SIMULATED: widget tests over AppContainer.inMemory and the real store.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_owner_session.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/intruder_evidence_screen.dart';
import 'package:smart_app_lock/ui/screens/security/intruder_settings_screen.dart';

import '../support/credential_change_grant.dart';
import '../support/intruder_fixtures.dart';

const String _pin = '482916';
const List<int> _pattern = <int>[1, 2, 3, 6, 9];

/// Blocks reads while armed, so a store operation can be held inside the
/// store's serialized section (queueing later operations behind it).
class _GateDb extends InMemoryLocalDatabase {
  Completer<void>? gate;

  @override
  Future<String?> getSetting(String key) async {
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    return super.getSetting(key);
  }
}

void main() {
  late AppContainer c;
  late DateTime t;

  setUp(() async {
    c = AppContainer.inMemory(
      intruderEvidence: StaticIntruderEvidenceService(),
      database: InMemoryLocalDatabase(),
    );
    await c.intruderStartup;
    t = DateTime(2026, 10, 22, 12);
    c.intruderOwnerSessions = IntruderOwnerSessionGate(now: () => t);
  });

  Finder image() => find.byKey(const Key('intruder_evidence_image'));

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark,
        onGenerateRoute: AppRouter.onGenerateRoute,
        home: IntruderSettingsScreen(container: c),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> typePin(WidgetTester tester, String pin,
      {bool last = true}) async {
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    final List<String> digits = pin.split('');
    for (int i = 0; i < digits.length; i++) {
      if (!last && i == digits.length - 1) return;
      await tester.tap(find.byKey(Key('pin_key_${digits[i]}')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> lastPinDigit(WidgetTester tester, String pin) async {
    await tester.tap(find.byKey(Key('pin_key_${pin[pin.length - 1]}')));
    await tester.pumpAndSettle();
  }

  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    await tester.pump(const Duration(milliseconds: 450));
    final Rect b = tester.getRect(find.byType(DsPatternGrid));
    final double pad = b.width * 0.10;
    final double step = (b.width - 2 * pad) / 2;
    Offset center(int n) => Offset(b.left + pad + ((n - 1) % 3) * step,
        b.top + pad + ((n - 1) ~/ 3) * step);
    final TestGesture g = await tester.startGesture(center(nodes.first));
    await tester.pump();
    await g.moveBy(const Offset(20, 0));
    await tester.pump();
    Offset cur = center(nodes.first).translate(20, 0);
    for (final int n in nodes.skip(1)) {
      final Offset target = center(n);
      for (int s = 1; s <= 6; s++) {
        await g.moveTo(Offset(cur.dx + (target.dx - cur.dx) * s / 6,
            cur.dy + (target.dy - cur.dy) * s / 6));
        await tester.pump();
      }
      cur = target;
    }
    await g.up();
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

  Future<void> openDetail(WidgetTester tester, int seq) async {
    await tapKey(tester, 'intruder_view_evidence');
    await typePin(tester, _pin);
    await tester
        .tap(find.byKey(ValueKey<String>('intruder_evidence_item_$seq')));
    await tester.pumpAndSettle();
    expect(image(), findsOneWidget);
  }

  /// Programmatic primary replacement PIN -> pattern (CR-3 grant).
  Future<void> replacePrimaryWithPattern() async {
    final grant = await grantWithPin(c.auth, _pin);
    expect(
        (await c.auth.enrollPattern(_pattern, authorization: grant)).isSuccess,
        isTrue);
    expect((await c.auth.status()).valueOrNull!.primary, AuthType.pattern);
  }

  void expectViewerClosed() {
    expect(find.byType(IntruderEvidenceScreen), findsNothing);
    expect(find.byType(IntruderEvidenceDetailScreen), findsNothing);
    expect(image(), findsNothing);
    expect(c.intruderOwnerSessions.current, isNull);
  }

  group('credential replacement at the commit point', () {
    testWidgets(
        'delete-one: primary replaced (PIN -> pattern) while the detail is '
        'open; the CURRENT credential verifies, but the session credential '
        'differs -> nothing deleted, viewer closed',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openDetail(tester, 1);
      await replacePrimaryWithPattern();
      await tapKey(tester, 'intruder_evidence_delete');
      await tapKey(tester, 'intruder_delete_confirm');
      expect(find.byType(PatternUnlockScreen), findsOneWidget,
          reason: 'verification always asks for the current primary');
      await drawPattern(tester, _pattern);
      expect((await c.intruderEvidence.list()).length, 1);
      expectViewerClosed();
    });

    testWidgets(
        'clear-all (viewer): primary replaced while the list is open -> '
        'nothing cleared, viewer closed', (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1, 2]);
      await pumpSettings(tester);
      await tapKey(tester, 'intruder_view_evidence');
      await typePin(tester, _pin);
      await replacePrimaryWithPattern();
      await tapKey(tester, 'intruder_evidence_clear_all');
      await tapKey(tester, 'intruder_clear_all_confirm');
      await drawPattern(tester, _pattern);
      expect((await c.intruderEvidence.list()).length, 2);
      expectViewerClosed();
    });
  });

  group('session expiry at the commit point', () {
    testWidgets(
        'delete-one: the session expires DURING its own verification -> the '
        'correct PIN changes nothing (post-verification check)',
        (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1]);
      await pumpSettings(tester);
      await openDetail(tester, 1);
      await tapKey(tester, 'intruder_evidence_delete');
      await tapKey(tester, 'intruder_delete_confirm');
      await typePin(tester, _pin, last: false);
      t = t.add(IntruderOwnerSessionGate.defaultMaxAge); // expires now
      await lastPinDigit(tester, _pin);
      expect((await c.intruderEvidence.list()).length, 1);
      expectViewerClosed();
    });

    testWidgets(
        'clear-all (viewer): the session expires during its verification -> '
        'nothing cleared', (WidgetTester tester) async {
      await c.auth.enrollPin(_pin);
      await seed(<int>[1, 2]);
      await pumpSettings(tester);
      await tapKey(tester, 'intruder_view_evidence');
      await typePin(tester, _pin);
      await tapKey(tester, 'intruder_evidence_clear_all');
      await tapKey(tester, 'intruder_clear_all_confirm');
      await typePin(tester, _pin, last: false);
      t = t.add(IntruderOwnerSessionGate.defaultMaxAge);
      await lastPinDigit(tester, _pin);
      expect((await c.intruderEvidence.list()).length, 2);
      expectViewerClosed();
    });
  });

  group('store commit predicate is evaluated AT the commit (queued op)', () {
    late _GateDb db;
    late IntruderEvidenceStore s;

    setUp(() async {
      db = _GateDb();
      s = IntruderEvidenceStore(
          db, AesGcmSettingsCipher(InMemorySecretStore()));
      expect(await s.save(seq: 1, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
      expect(await s.save(seq: 2, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
    });

    test(
        'delete queued behind a held store op: authorization lost while '
        'queued -> cancelled, nothing deleted', () async {
      bool valid = true;
      db.gate = Completer<void>();
      final Future<List<EvidenceItem>> held = s.list(); // holds the lock
      final Future<EvidenceDeleteResult> del =
          s.delete(1, stillValid: () => valid);
      await Future<void>.delayed(Duration.zero);
      valid = false; // session expired / closed while queued
      db.gate!.complete();
      db.gate = null;
      await held;
      expect(await del, EvidenceDeleteResult.cancelled);
      expect((await s.list()).map((EvidenceItem e) => e.seq), <int>[1, 2]);
    });

    test(
        'clear-all queued behind a held store op: authorization lost while '
        'queued -> cancelled, nothing cleared', () async {
      bool valid = true;
      db.gate = Completer<void>();
      final Future<List<EvidenceItem>> held = s.list();
      final Future<EvidenceClearResult> clr =
          s.clearAll(floorSeq: 2, stillValid: () => valid);
      await Future<void>.delayed(Duration.zero);
      valid = false;
      db.gate!.complete();
      db.gate = null;
      await held;
      expect(await clr, EvidenceClearResult.cancelled);
      expect((await s.list()).length, 2);
    });
  });
}
