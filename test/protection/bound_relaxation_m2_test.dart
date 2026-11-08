// Phase 11 / M2: the bound relaxation protocol ("probe-then-flag") at the
// protection bootstrap, against the SIMULATED native model
// (StaticWatcherService mirrors SmartRuleSnapshotResolver: unflagged
// relaxing → held union; flagged → applied from whatever it holds).
//
// These tests prove the isolation property directly: the native relaxation
// flag is only ever sent right after an unflagged probe of the operation's
// own expected-before state was APPLIED, so the flag relaxes exactly the
// authorized difference and can never release an unrelated held reduction.
// All results are SIMULATED (no device).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/security_profile_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';
import 'package:smart_app_lock/protection/bound_relaxation.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _L = AppSecurityLevel;

const String _pin = '2468';
const String _notes = 'com.example.notes'; // protected, Standard
const String _chat = 'com.example.chat'; // protected, Sensitive
const String _maps = 'com.example.maps'; // installed, NOT protected
final DateTime _now = DateTime(2026, 11, 2, 12); // Monday noon

final SmartRule _notesCritical = SmartRule(
  id: 'notes-critical',
  name: 'Notes Critical',
  targetPackages: const <String>[_notes],
  days: SmartRuleDays.everyDay,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

final SmartRule _chatCritical = SmartRule(
  id: 'chat-critical',
  name: 'Chat Critical',
  targetPackages: const <String>[_chat],
  days: SmartRuleDays.everyDay,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

SecurityProfileSet _activeGuest() =>
    SecurityProfileSet.defaults().withActive(SecurityProfileKind.guest.id);

class _Db extends InMemoryLocalDatabase {
  bool failProfileWrites = false;

  @override
  Future<void> setSetting(String key, String value) {
    if (key == SecurityProfileRepositoryImpl.storageKey && failProfileWrites) {
      throw StateError('simulated profile write failure');
    }
    return super.setSetting(key, value);
  }
}

class _Fx {
  _Fx(this.c, this.db, this.kv, this.secrets);

  final AppContainer c;
  final _Db db;
  final InMemoryKeyValueStore kv;
  final InMemorySecretStore secrets;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;

  static AppContainer _container(
    _Db db,
    InMemoryKeyValueStore kv,
    InMemorySecretStore secrets,
  ) =>
      AppContainer.inMemory(
        apps: const <AppEntry>[
          AppEntry(packageName: _notes, label: 'Notes'),
          AppEntry(packageName: _chat, label: 'Chat'),
          AppEntry(packageName: _maps, label: 'Maps'),
        ],
        database: db,
        secretStore: secrets,
        keyValueStore: kv,
        accessibilityEnabled: true,
        overlayGranted: true,
        accessClock: () => _now,
      );

  static Future<_Fx> create({
    List<SmartRule> rules = const <SmartRule>[],
    SecurityProfileSet? profiles,
  }) async {
    final _Db db = _Db();
    final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer c = _container(db, kv, secrets);
    (c.watcher as StaticWatcherService).ruleClock = () => _now;
    await c.auth.enrollPin(_pin);
    await c.protectedApps.add(ProtectedApp(
      packageName: _notes,
      label: 'Notes',
      addedAt: DateTime(2026, 11, 1),
    ));
    await c.protectedApps.add(ProtectedApp(
      packageName: _chat,
      label: 'Chat',
      addedAt: DateTime(2026, 11, 1),
      securityLevel: _L.sensitive,
    ));
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    if (profiles != null) {
      expect(
        (await c.securityProfiles.saveProfiles(profiles,
                expected: SecurityProfileSet.defaults()))
            .isSuccess,
        isTrue,
      );
    }
    final _Fx fx = _Fx(c, db, kv, secrets);
    final Result<dynamic> sync = await c.protectionBootstrap.synchronize();
    expect(sync.isSuccess, isTrue);
    expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
    return fx;
  }

  /// SIMULATED process death: a new Dart process over the same stores;
  /// native (the static watcher) keeps what it last persisted.
  _Fx restart() {
    final List<Map<String, Object?>> nativeRules =
        List<Map<String, Object?>>.of(watcher.smartRules);
    final AppContainer next = _container(db, kv, secrets);
    final StaticWatcherService w = next.watcher as StaticWatcherService;
    w.ruleClock = () => _now;
    w
      ..protectionConfigured = true
      ..running = true
      ..smartRules.addAll(nativeRules);
    return _Fx(next, db, kv, secrets);
  }

  int get flagged => watcher.receivedPolicies
      .where(
          (ProtectionPolicySnapshot? p) => p?.authorizedRuleRelaxation == true)
      .length;

  _L? native(String pkg) => watcher.simulatedRuleLevel(pkg, _now);

  Future<SecurityProfileSet> profiles() async =>
      (await c.securityProfiles.getProfiles()).valueOrNull!;

  /// Leave Guest for Normal through the bound protocol.
  Future<BoundRelaxationResult> leaveGuest({
    bool Function(Set<String>)? authorize,
    List<Set<String>>? seen,
  }) =>
      c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: authorize ??
            (Set<String> p) {
              seen?.add(p);
              return true;
            },
        profilesBefore: _activeGuest(),
        profilesAfter: SecurityProfileSet.defaults(),
        commit: () => c.securityProfiles.saveProfiles(
          SecurityProfileSet.defaults(),
          expected: _activeGuest(),
        ),
      );
}

List<String> _t(List<Map<String, Object?>>? t) =>
    (t ?? const <Map<String, Object?>>[])
        .map((Map<String, Object?> e) => e.toString())
        .toList();

List<Map<String, Object?>> _transport(
  List<SmartRule> rules,
  SecurityProfile profile,
) =>
    SecurityProfilePolicy.nativeTransport(
      rules,
      profile,
      const <String>{_notes, _chat},
    );

void main() {
  group('P11-M2 bound relaxation: exact before → after (SIMULATED)', () {
    test(
        'BR-1. Guest → Normal: the proof is asked for EXACTLY the relaxed '
        'apps; an unflagged probe of Guest precedes ONE flagged Normal; the '
        'document is committed only after the applied ack', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      expect(fx.native(_notes), _L.critical);
      final int before = fx.watcher.receivedPolicies.length;
      final List<Set<String>> seen = <Set<String>>[];
      final BoundRelaxationResult r = await fx.leaveGuest(seen: seen);

      expect(r.status, BoundRelaxationStatus.applied);
      expect(seen, <Set<String>>[
        <String>{_notes, _chat},
      ]);
      final List<ProtectionPolicySnapshot?> sent =
          fx.watcher.receivedPolicies.sublist(before);
      expect(sent, hasLength(2));
      expect(sent[0]!.authorizedRuleRelaxation, isFalse, reason: 'probe');
      expect(_t(sent[0]!.smartRules),
          _t(_transport(const <SmartRule>[], _activeGuest().active)));
      expect(sent[1]!.authorizedRuleRelaxation, isTrue, reason: 'flag');
      expect(_t(sent[1]!.smartRules), isEmpty);
      expect(
          sent.every(
              (ProtectionPolicySnapshot? p) => p!.authorizedDowngrades.isEmpty),
          isTrue);
      expect(fx.native(_notes), isNull);
      expect((await fx.profiles()).activeProfileId, 'normal');
      // A relaxation grants nothing.
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.c.protectionBootstrap.profileCache.active.id, 'normal');
    });

    test(
        'BR-2. nothing relaxed (Normal → Guest): no proof is consumed and no '
        'flag is sent', () async {
      final _Fx fx = await _Fx.create();
      int asked = 0;
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: (Set<String> _) {
          asked++;
          return true;
        },
        profilesBefore: SecurityProfileSet.defaults(),
        profilesAfter: _activeGuest(),
        commit: () => fx.c.securityProfiles.saveProfiles(
          _activeGuest(),
          expected: SecurityProfileSet.defaults(),
        ),
      );
      expect(r.status, BoundRelaxationStatus.applied);
      expect(asked, 0);
      expect(fx.flagged, 0);
      expect(fx.native(_notes), _L.critical);
    });
  });

  group('P11-M2 CR-2 isolation: no cross-authorization (SIMULATED)', () {
    test(
        'ISO-1 (#23/#24). native HOLDS an unrelated rule reduction (storage '
        'reduced, native union): a profile reduction is BLOCKED, no flag is '
        'sent, the held rule stays enforced and the profile is unchanged',
        () async {
      // Kids raises Notes only; a separate rule keeps Chat Critical.
      final SecurityProfileSet kids = SecurityProfileSet.defaults()
          .withProfile(SecurityProfile(
            kind: SecurityProfileKind.kids,
            appLevels: const <String, AppSecurityLevel>{_notes: _L.critical},
          ))
          .withActive('kids');
      final _Fx fx = await _Fx.create(
        rules: <SmartRule>[_chatCritical],
        profiles: kids,
      );
      // An unconfirmed rule deletion (e.g. Option A rollback failed).
      expect((await fx.c.smartRules.deleteRule(_chatCritical.id)).isSuccess,
          isTrue);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      expect(fx.native(_chat), _L.critical, reason: 'held union');

      final int flaggedBefore = fx.flagged;
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: (Set<String> _) => true,
        profilesBefore: kids,
        profilesAfter: SecurityProfileSet.defaults(),
        commit: () => fx.c.securityProfiles
            .saveProfiles(SecurityProfileSet.defaults(), expected: kids),
      );
      expect(r.status, BoundRelaxationStatus.blocked);
      expect(fx.flagged, flaggedBefore, reason: 'the flag was never sent');
      expect(fx.native(_chat), _L.critical, reason: 'rule still held');
      expect(fx.native(_notes), _L.critical, reason: 'Kids still enforced');
      expect((await fx.profiles()).activeProfileId, 'kids');
    });

    test(
        'ISO-2 (reverse). native HOLDS a profile reduction (storage Normal, '
        'native Guest): a PIN-bound RULE reduction is BLOCKED and never '
        'releases Guest', () async {
      final _Fx fx = await _Fx.create(
        rules: <SmartRule>[_notesCritical],
        profiles: _activeGuest(),
      );
      // Storage leaves Guest without native confirmation (held).
      expect(
        (await fx.c.securityProfiles.saveProfiles(SecurityProfileSet.defaults(),
                expected: _activeGuest()))
            .isSuccess,
        isTrue,
      );
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      // Now a rule deletion (write-first, Phase 10 path).
      expect((await fx.c.smartRules.deleteRule(_notesCritical.id)).isSuccess,
          isTrue);
      final int flaggedBefore = fx.flagged;
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.ruleReduction,
        authorize: (Set<String> _) => true,
        rulesBefore: <SmartRule>[_notesCritical],
        rulesAfter: const <SmartRule>[],
        storageHoldsAfter: true,
      );
      expect(r.status, BoundRelaxationStatus.blocked);
      expect(fx.flagged, flaggedBefore);
      expect(fx.native(_chat), _L.critical, reason: 'Guest still held');
    });

    test(
        'ISO-3 (#26). wrong before-binding: storage no longer holds the '
        'expected-before profile → conflict; nothing is sent at all', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      final int sentBefore = fx.watcher.receivedPolicies.length;
      bool asked = false;
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: (Set<String> _) => asked = true,
        // The screen thinks Kids-with-Critical is active (stale form).
        profilesBefore: SecurityProfileSet.defaults()
            .withProfile(SecurityProfile(
              kind: SecurityProfileKind.kids,
              allProtectedLevel: _L.critical,
            ))
            .withActive('kids'),
        profilesAfter: SecurityProfileSet.defaults(),
      );
      expect(r.status, BoundRelaxationStatus.conflict);
      expect(asked, isFalse, reason: 'no proof consumed on a conflict');
      expect(fx.watcher.receivedPolicies.length, sentBefore);
      expect(fx.native(_notes), _L.critical);
    });

    test(
        'ISO-4. concurrent rule change between authorization and sync '
        'invalidates the profile operation (rules binding)', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      expect(
          (await fx.c.smartRules.saveRule(_notesCritical)).isSuccess, isTrue);
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: (Set<String> _) => true,
        rulesBefore: const <SmartRule>[],
        rulesAfter: const <SmartRule>[],
        profilesBefore: _activeGuest(),
        profilesAfter: SecurityProfileSet.defaults(),
      );
      expect(r.status, BoundRelaxationStatus.conflict);
      expect(fx.flagged, 0);
      expect((await fx.profiles()).activeProfileId, 'guest');
    });

    test(
        'ISO-5. a refused proof (wrong intent / expired / reused) → denied; '
        'no probe and no flag are sent', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      final int sentBefore = fx.watcher.receivedPolicies.length;
      final BoundRelaxationResult r =
          await fx.leaveGuest(authorize: (Set<String> _) => false);
      expect(r.status, BoundRelaxationStatus.denied);
      expect(fx.watcher.receivedPolicies.length, sentBefore);
      expect((await fx.profiles()).activeProfileId, 'guest');
      expect(fx.native(_notes), _L.critical);
    });

    test(
        'ISO-6. unprotected apps are never part of the relaxed scope and '
        'never protected by Guest', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      expect(fx.native(_maps), isNull);
      expect(fx.watcher.protectedPackages, <String>{_notes, _chat});
      final List<Set<String>> seen = <Set<String>>[];
      await fx.leaveGuest(seen: seen);
      expect(seen.single.contains(_maps), isFalse);
    });
  });

  group('P11-M2 final gate: probe durability and serialization (SIMULATED)',
      () {
    test(
        'GATE-1. a probe native resolved but could NOT persist '
        '(persisted=false, memory = held union) is never treated as APPLIED: '
        'unknown, the flag is never sent, the unrelated held reduction stays '
        'enforced, the profile is unchanged', () async {
      final SecurityProfileSet kids = SecurityProfileSet.defaults()
          .withProfile(SecurityProfile(
            kind: SecurityProfileKind.kids,
            appLevels: const <String, AppSecurityLevel>{_notes: _L.critical},
          ))
          .withActive('kids');
      final _Fx fx = await _Fx.create(
        rules: <SmartRule>[_chatCritical],
        profiles: kids,
      );
      expect((await fx.c.smartRules.deleteRule(_chatCritical.id)).isSuccess,
          isTrue);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      final int flaggedBefore = fx.flagged;
      fx.watcher.configureFault = (ProtectionPolicySnapshot? p) =>
          p?.authorizedRuleRelaxation == true
              ? null
              : StaticConfigureFault.failAfterApply;
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: (Set<String> _) => true,
        profilesBefore: kids,
        profilesAfter: SecurityProfileSet.defaults(),
        commit: () => fx.c.securityProfiles
            .saveProfiles(SecurityProfileSet.defaults(), expected: kids),
      );
      expect(r.status, BoundRelaxationStatus.unknown);
      expect(fx.flagged, flaggedBefore, reason: 'no flag after a failed probe');
      expect(fx.native(_chat), _L.critical, reason: 'held union kept');
      expect(fx.native(_notes), _L.critical);
      expect((await fx.profiles()).activeProfileId, 'kids');
    });

    test(
        'GATE-2. probe, flag and commit are ONE serialized section: a '
        'concurrent synchronize() cannot interleave between the probe and the '
        'flag; it runs afterwards and sends the committed profile unflagged',
        () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      final int start = fx.watcher.receivedPolicies.length;
      final Completer<void> gate = Completer<void>();
      fx.watcher.configureGate = gate;
      final Future<BoundRelaxationResult> bound = fx.leaveGuest();
      final Future<Result<dynamic>> sync =
          fx.c.protectionBootstrap.synchronize();
      await pumpEventQueue();
      // Only the probe has reached native; the sync waits in the queue.
      expect(fx.watcher.receivedPolicies.length, start + 1);
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isFalse);
      fx.watcher.configureGate = null;
      gate.complete();
      expect((await bound).status, BoundRelaxationStatus.applied);
      expect((await sync).isSuccess, isTrue);
      final List<ProtectionPolicySnapshot?> sent =
          fx.watcher.receivedPolicies.sublist(start);
      expect(sent, hasLength(3));
      expect(_t(sent[0]!.smartRules),
          _t(_transport(const <SmartRule>[], _activeGuest().active)),
          reason: 'probe = expected-before');
      expect(sent[0]!.authorizedRuleRelaxation, isFalse);
      expect(sent[1]!.authorizedRuleRelaxation, isTrue, reason: 'flag');
      expect(_t(sent[1]!.smartRules), isEmpty);
      expect(sent[2]!.authorizedRuleRelaxation, isFalse, reason: 'sync');
      expect(_t(sent[2]!.smartRules), isEmpty,
          reason: 'the sync sees the committed Normal');
      expect((await fx.profiles()).activeProfileId, 'normal');
    });
  });

  group('P11-M2 precedence on the Dart floor (SIMULATED)', () {
    final SmartRule chatSensitive = SmartRule(
      id: 'chat-sensitive',
      name: 'Chat Sensitive',
      targetPackages: const <String>[_chat],
      days: SmartRuleDays.everyDay,
      time: const SmartRuleTime.allDay(),
      action: SmartRuleAction.sensitive,
    );

    test(
        'PR-1. the STRICTER of profile overlay and matching rule decides, in '
        'both directions (Critical > Sensitive > Standard); never below the '
        'saved level', () async {
      // Kids: Notes Sensitive (overlay weaker than the Critical rule);
      // Chat Critical (overlay stricter than the Sensitive rule).
      final SecurityProfileSet kids = SecurityProfileSet.defaults()
          .withProfile(SecurityProfile(
            kind: SecurityProfileKind.kids,
            appLevels: const <String, AppSecurityLevel>{
              _notes: _L.sensitive,
              _chat: _L.critical,
            },
          ))
          .withActive('kids');
      final _Fx fx = await _Fx.create(
        rules: <SmartRule>[_notesCritical, chatSensitive],
        profiles: kids,
      );
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isTrue);
      expect(fx.c.protectionBootstrap.extraLevelFor(_notes, _now), _L.critical,
          reason: 'the rule is stricter');
      expect(fx.c.protectionBootstrap.extraLevelFor(_chat, _now), _L.critical,
          reason: 'the profile is stricter');
      expect(fx.c.protectionBootstrap.extraLevelFor(_maps, _now), isNull);
      // The real access decision uses the same floor.
      final DefaultAccessController access =
          fx.c.accessController as DefaultAccessController;
      expect((await access.grantAccess(_notes)).isSuccess, isTrue);
      expect(access.sessionFor(_notes)?.securityLevel, _L.critical);
      expect((await access.grantAccess(_chat)).isSuccess, isTrue);
      expect(access.sessionFor(_chat)?.securityLevel, _L.critical);
      // Native agrees.
      expect(fx.native(_notes), _L.critical);
      expect(fx.native(_chat), _L.critical);
    });
  });

  group('P11-M2 acknowledgement & recovery (SIMULATED)', () {
    for (final StaticConfigureFault fault in StaticConfigureFault.values) {
      test(
          'AR-1 (#29/#30). flagged write $fault → not applied: the stricter '
          'Guest is re-sent unflagged and acknowledged; the document is '
          'NEVER committed', () async {
        final _Fx fx = await _Fx.create(profiles: _activeGuest());
        fx.watcher.configureFault = (ProtectionPolicySnapshot? p) =>
            p?.authorizedRuleRelaxation == true ? fault : null;
        final BoundRelaxationResult r = await fx.leaveGuest();
        expect(r.status, BoundRelaxationStatus.notApplied);
        expect(fx.flagged, 1);
        final ProtectionPolicySnapshot last = fx.watcher.receivedPolicies.last!;
        expect(last.authorizedRuleRelaxation, isFalse);
        expect(_t(last.smartRules),
            _t(_transport(const <SmartRule>[], _activeGuest().active)));
        expect(fx.native(_notes), _L.critical);
        expect((await fx.profiles()).activeProfileId, 'guest',
            reason: 'storage untouched: nothing to roll back');
        expect(fx.c.protectionBootstrap.profileCache.active.id, 'guest');
      });
    }

    test(
        'AR-2. flagged write AND the recovery re-send fail → unknown (never '
        'applied, never "nothing changed"); document not committed', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      bool flaggedSeen = false;
      fx.watcher.configureFault = (ProtectionPolicySnapshot? p) {
        if (p?.authorizedRuleRelaxation == true) flaggedSeen = true;
        return flaggedSeen ? StaticConfigureFault.failBeforeApply : null;
      };
      final BoundRelaxationResult r = await fx.leaveGuest();
      expect(r.status, BoundRelaxationStatus.unknown);
      expect((await fx.profiles()).activeProfileId, 'guest');
      expect(fx.native(_notes), _L.critical);
    });

    test('AR-3. probe transport failure → unknown; the flag is never sent',
        () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      fx.watcher.configureFault =
          (ProtectionPolicySnapshot? p) => StaticConfigureFault.failBeforeApply;
      final BoundRelaxationResult r = await fx.leaveGuest();
      expect(r.status, BoundRelaxationStatus.unknown);
      expect(fx.flagged, 0);
      expect(fx.native(_notes), _L.critical);
    });

    test(
        'AR-4 (#31). native applied the relaxation but the document write '
        'failed → the stricter state is re-sent; profile stays Guest',
        () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      fx.db.failProfileWrites = true;
      final BoundRelaxationResult r = await fx.leaveGuest();
      expect(r.status, BoundRelaxationStatus.notApplied);
      expect(fx.flagged, 1);
      expect(fx.native(_notes), _L.critical, reason: 'raised back');
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isFalse);
      fx.db.failProfileWrites = false;
      expect((await fx.profiles()).activeProfileId, 'guest');
    });

    test(
        'AR-5 (#32, process death). killed after native applied Normal but '
        'BEFORE the document commit (and before recovery): the restart sync '
        're-applies the saved, stricter Guest; nothing is silently confirmed',
        () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      // Simulate death right after the flagged ack: the commit never
      // happens and no recovery snapshot is sent.
      bool afterFlag = false;
      fx.watcher.configureFault = (ProtectionPolicySnapshot? p) {
        if (afterFlag) return StaticConfigureFault.failBeforeApply;
        if (p?.authorizedRuleRelaxation == true) afterFlag = true;
        return null;
      };
      fx.db.failProfileWrites = true;
      await fx.leaveGuest();
      expect(fx.native(_notes), isNull, reason: 'native relaxed (simulated)');

      final _Fx next = fx.restart();
      fx.db.failProfileWrites = false;
      expect(next.c.protectionBootstrap.extraLevelsCurrent, isFalse,
          reason: 'R-A floor until both reads succeed');
      final Result<dynamic> sync =
          await next.c.protectionBootstrap.synchronize();
      expect(sync.isSuccess, isTrue);
      expect(next.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
      expect(next.native(_notes), _L.critical, reason: 'Guest re-applied');
      expect((await next.profiles()).activeProfileId, 'guest');
      expect(next.watcher.receivedPolicies.last!.authorizedRuleRelaxation,
          isFalse);
    });

    test(
        'AR-6. restart with a stored Guest after a completed switch to Guest: '
        'one profile loads, enforced after the restart sync', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      final _Fx next = fx.restart();
      await next.c.protectionBootstrap.synchronize();
      expect(next.c.protectionBootstrap.profileCache.active.id, 'guest');
      expect(next.native(_notes), _L.critical);
    });

    test(
        'AR-7. confirmSaved is bound to the displayed saved rules: a change '
        'since display → conflict, nothing sent', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_notesCritical]);
      final int sentBefore = fx.watcher.receivedPolicies.length;
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.confirmSaved,
        authorize: (Set<String> _) => true,
        rulesBefore: const <SmartRule>[],
        rulesAfter: const <SmartRule>[],
        storageHoldsAfter: true,
      );
      expect(r.status, BoundRelaxationStatus.conflict);
      expect(fx.watcher.receivedPolicies.length, sentBefore);
    });

    test(
        'AR-8. the broad flag can no longer be requested through '
        'synchronize(): every plain sync is unflagged', () async {
      final _Fx fx = await _Fx.create(profiles: _activeGuest());
      await fx.c.protectionBootstrap.synchronize();
      await fx.c.protectionBootstrap
          .synchronize(authorizedDowngrades: <String>{_notes});
      expect(fx.flagged, 0);
      expect(
        SmartRulePolicy.nativeTransport(const <SmartRule>[]),
        isEmpty,
      );
    });
  });
}
