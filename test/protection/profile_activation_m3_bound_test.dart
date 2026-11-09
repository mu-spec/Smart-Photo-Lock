// Phase 11 / M3 (§6, §7, §10): "Apply profile" activation at the protection
// bootstrap, against the SIMULATED native model (StaticWatcherService mirrors
// SmartRuleSnapshotResolver: unflagged relaxing → held union; flagged →
// applied). Proves: ONE combined transport (v1, no protocol change); the Dart
// floor and native agree; expiry needs no message, proof or flag; manual
// reductions of an activation go through the bound protocol for EXACTLY the
// relaxed apps; a rule proof never releases a held profile reduction; a
// failed commit raises back; restart is deterministic. All SIMULATED.

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
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/bound_relaxation.dart';
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
const Set<String> _protected = <String>{_notes, _chat};
const String _tripId = 'custom-00000000000a';
final DateTime _now = DateTime(2026, 11, 2, 12); // Monday noon
final DateTime _evening = DateTime(2026, 11, 2, 18); // Monday 18:00

/// The decision clock of the access controller and the simulated native
/// resolver. Reset to [_now] by [_Fx.create]; only BA-6 moves it.
DateTime _clock = _now;

/// Every day 09:00–17:00: active at [_now], expired at [_evening].
SmartRule _act(String profile, {String id = 'act-rule', bool on = true}) =>
    SmartRule(
      id: id,
      name: 'Daytime $profile',
      targetPackages: const <String>[],
      days: SmartRuleDays.everyDay,
      time: SmartRuleTime.window(startMinute: 540, endMinute: 1020),
      action: SmartRuleAction.applyProfile,
      profileId: profile,
      enabled: on,
    );

SecurityProfile _trip(_L all) =>
    SecurityProfile.custom(id: _tripId, name: 'Trip', allProtectedLevel: all);

SecurityProfileSet _withTrip(_L all, {String active = 'normal'}) =>
    SecurityProfileSet.defaults().withAdded(_trip(all)).withActive(active);

class _Db extends InMemoryLocalDatabase {
  bool failProfileWrites = false;
  bool failProfileReads = false;

  @override
  Future<String?> getSetting(String key) {
    if (key == SecurityProfileRepositoryImpl.storageKey && failProfileReads) {
      throw StateError('simulated profile read failure');
    }
    return super.getSetting(key);
  }

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
        accessClock: () => _clock,
      );

  static Future<_Fx> create({
    List<SmartRule> rules = const <SmartRule>[],
    SecurityProfileSet? profiles,
    SmartRuleSyncStatus expectStatus = SmartRuleSyncStatus.applied,
  }) async {
    _clock = _now;
    final _Db db = _Db();
    final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer c = _container(db, kv, secrets);
    (c.watcher as StaticWatcherService).ruleClock = () => _clock;
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
    if (profiles != null) {
      expect(
        (await c.securityProfiles.saveProfiles(profiles,
                expected: SecurityProfileSet.defaults()))
            .isSuccess,
        isTrue,
      );
    }
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    final _Fx fx = _Fx(c, db, kv, secrets);
    final Result<dynamic> sync = await c.protectionBootstrap.synchronize();
    expect(sync.isSuccess, isTrue);
    expect(fx.watcher.lastRuleStatus, expectStatus);
    return fx;
  }

  /// SIMULATED process death: a new Dart process over the same stores;
  /// native keeps what it last persisted.
  _Fx restart() {
    final List<Map<String, Object?>> nativeRules =
        List<Map<String, Object?>>.of(watcher.smartRules);
    final AppContainer next = _container(db, kv, secrets);
    final StaticWatcherService w = next.watcher as StaticWatcherService;
    w.ruleClock = () => _clock;
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

  _L? native(String pkg, [DateTime? at]) =>
      watcher.simulatedRuleLevel(pkg, at ?? _now);

  Future<SecurityProfileSet> profiles() async =>
      (await c.securityProfiles.getProfiles()).valueOrNull!;

  Future<List<SmartRule>> rules() async =>
      (await c.smartRules.getRules()).valueOrNull!;

  /// The rule path (M2): storage already holds [after]; bound the flag.
  Future<BoundRelaxationResult> ruleReduction(
    List<SmartRule> before,
    List<SmartRule> after,
    SecurityProfileSet profiles, {
    bool Function(Set<String>)? authorize,
    List<Set<String>>? seen,
  }) async {
    expect((await c.smartRules.replaceRules(after, expected: before)).isSuccess,
        isTrue);
    return c.protectionBootstrap.applyBoundRelaxation(
      intent: BoundRelaxationIntent.ruleReduction,
      authorize: authorize ??
          (Set<String> p) {
            seen?.add(p);
            return true;
          },
      rulesBefore: before,
      rulesAfter: after,
      profilesBefore: profiles,
      profilesAfter: profiles,
      storageHoldsAfter: true,
    );
  }
}

List<String> _t(List<Map<String, Object?>>? t) =>
    (t ?? const <Map<String, Object?>>[])
        .map((Map<String, Object?> e) => e.toString())
        .toList();

void main() {
  group('P11-M3 activation transport and floor (SIMULATED)', () {
    test(
        'BA-1. ONE combined v1 transport; native and the Dart floor agree; '
        'the manual profile, saved levels and sessions are untouched',
        () async {
      final List<SmartRule> rules = <SmartRule>[_act('guest')];
      final _Fx fx = await _Fx.create(rules: rules);
      final ProtectionPolicySnapshot sent = fx.watcher.receivedPolicies.last!;
      expect(
        _t(sent.smartRules),
        _t(SecurityProfilePolicy.combinedTransport(
            rules, SecurityProfileSet.defaults(), _protected)),
      );
      expect(sent.authorizedRuleRelaxation, isFalse);
      expect(sent.authorizedDowngrades, isEmpty);
      expect(
          sent.levels,
          <String, _L>{
            _notes: _L.standard,
            _chat: _L.sensitive,
          },
          reason: 'baseline levels are never modified');
      final SmartRuleNativeRecord record =
          fx.c.protectionBootstrap.lastRuleExchange!;
      expect(record.status, SmartRuleSyncStatus.applied);
      expect(
        _t(record.sentActivationOverlay),
        _t(SmartRulePolicy.nativeTransport(
            SecurityProfilePolicy.activationRules(
                rules, SecurityProfileSet.defaults(), _protected))),
      );
      for (final String pkg in <String>[_notes, _chat]) {
        expect(fx.native(pkg), _L.critical, reason: pkg);
        expect(fx.c.protectionBootstrap.extraLevelFor(pkg, _now), _L.critical);
        expect(fx.native(pkg, _evening), isNull);
        expect(fx.c.protectionBootstrap.extraLevelFor(pkg, _evening), isNull);
      }
      expect(fx.native(_maps), isNull, reason: 'never enrols an app');
      expect(fx.c.protectionBootstrap.extraLevelFor(_maps, _now), isNull);
      expect((await fx.profiles()).activeProfileId, 'normal');
      expect(fx.watcher.authorizedPackages, isEmpty);
    });

    test(
        'BA-2 (§7B). expiry needs NO message, proof or flag: native '
        'evaluates the same stored snapshot at decision time', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act('guest')]);
      final int sends = fx.watcher.receivedPolicies.length;
      expect(fx.native(_notes, _now), _L.critical);
      expect(fx.native(_notes, _evening), isNull);
      expect(fx.native(_notes, _now.add(const Duration(days: 1))), _L.critical,
          reason: 'and it comes back the next day');
      expect(fx.watcher.receivedPolicies.length, sends);
      expect(fx.flagged, 0);
      // A re-sync at any time is an identical, unflagged, applied snapshot.
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
      expect(fx.flagged, 0);
    });

    test('BA-3 (R2). a dangling profile reference is Critical in its window',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act(_tripId)]);
      expect(fx.native(_notes), _L.critical);
      expect(fx.native(_chat), _L.critical);
      expect(fx.native(_notes, _evening), isNull);
      expect(fx.c.protectionBootstrap.extraLevelFor(_notes, _now), _L.critical);
    });

    test(
        'BA-4 (R-A). profiles unreadable: extra levels are not current (the '
        'floor treats protected apps as Critical) and nothing is relaxed',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act('guest')]);
      final List<Map<String, Object?>> nativeBefore =
          List<Map<String, Object?>>.of(fx.watcher.smartRules);
      fx.db.failProfileReads = true;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isFalse);
      expect(fx.flagged, 0);
      expect(_t(fx.watcher.smartRules), _t(nativeBefore),
          reason: 'native keeps the stricter rules');
      expect(fx.native(_notes), _L.critical);
    });

    test('BA-5. restart: a new process sends the identical combined transport',
        () async {
      final List<SmartRule> rules = <SmartRule>[_act('guest')];
      final _Fx fx = await _Fx.create(
          rules: rules, profiles: _withTrip(_L.sensitive, active: _tripId));
      final List<String> first =
          _t(fx.watcher.receivedPolicies.last!.smartRules);
      final _Fx next = fx.restart();
      await next.c.protectionBootstrap.synchronize();
      expect(_t(next.watcher.receivedPolicies.last!.smartRules), first);
      expect(next.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
      expect(next.native(_notes), _L.critical);
      expect(next.native(_notes, _evening), _L.sensitive,
          reason: 'manual Trip remains after expiry');
      expect(next.flagged, 0);
    });

    test(
        'BA-6 (§7B, final gate). overnight scheduled Guest (Sat/Sun '
        '22:00–06:00): midnight and weekday roll-over follow the stored '
        'snapshot; expiry at 06:00 sends nothing, flags nothing and grants '
        'no session, grace or authorization; the manual profile is unchanged',
        () async {
      final SmartRule overnight = SmartRule(
        id: 'night-guest',
        name: 'Weekend nights',
        targetPackages: const <String>[],
        days: const <int>[6, 7],
        time: SmartRuleTime.window(startMinute: 1320, endMinute: 360),
        action: SmartRuleAction.applyProfile,
        profileId: 'guest',
      );
      final _Fx fx = await _Fx.create(rules: <SmartRule>[overnight]);
      final int sends = fx.watcher.receivedPolicies.length;
      DateTime at(int day, int h, int m, [int s = 0]) =>
          DateTime(2026, 11, day, h, m, s); // 2 = Mon … 8 = Sun, 9 = Mon
      // Boundaries across midnight and weekdays (same stored snapshot).
      final Map<DateTime, _L?> expected = <DateTime, _L?>{
        at(6, 23, 0): null, // Fri night: Friday is not a rule day
        at(7, 5, 59): null, // Sat early: would belong to Friday's window
        at(7, 21, 59): null,
        at(7, 22, 0): _L.critical, // Sat 22:00 start
        at(7, 23, 59): _L.critical,
        at(8, 0, 0): _L.critical, // midnight Sat → Sun
        at(8, 5, 59): _L.critical,
        at(8, 6, 0): null, // Sun 06:00 expiry
        at(8, 22, 0): _L.critical, // Sun night window
        at(9, 0, 0): _L.critical, // midnight Sun → Mon (week roll-over)
        at(9, 5, 59): _L.critical,
        at(9, 6, 0): null, // Mon 06:00 expiry
      };
      expected.forEach((DateTime t, _L? want) {
        expect(fx.native(_notes, t), want, reason: 'notes at $t');
        expect(fx.c.protectionBootstrap.extraLevelFor(_notes, t), want,
            reason: 'Dart floor at $t');
      });

      // A Critical unlock inside the window …
      final DefaultAccessController access =
          fx.c.accessController as DefaultAccessController;
      access.setGracePeriod(const Duration(seconds: 30));
      _clock = at(8, 5, 59);
      expect(await access.evaluate(_notes), AccessDecision.challenge);
      expect((await access.grantAccess(_notes)).valueOrNull!.securityLevel,
          _L.critical);
      // … then the window expires and the user leaves.
      _clock = at(8, 6, 0, 5);
      await access.revokeAccess(_notes);
      expect(access.departureAtFor(_notes), isNull,
          reason: 'a Critical unlock never turns into Standard grace');
      expect(access.sessionFor(_notes), isNull);
      expect(await access.evaluate(_notes), AccessDecision.challenge,
          reason: 'expiry never unlocks: Standard still needs a challenge');
      expect(fx.watcher.authorizedPackages, isNot(contains(_notes)));
      expect(access.sessionFor(_chat), isNull,
          reason: 'expiry authorizes no other app');

      // Expiry contacted nobody, and a re-sync is identical and unflagged.
      expect(fx.watcher.receivedPolicies.length, sends);
      expect(fx.flagged, 0);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.flagged, 0);
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
      expect((await fx.profiles()).activeProfileId, 'normal',
          reason: 'a scheduled profile never changes the manual profile');

      // A new process after expiry: same persisted snapshot, no session.
      final _Fx next = fx.restart();
      final DefaultAccessController access2 =
          next.c.accessController as DefaultAccessController;
      expect(access2.sessionFor(_notes), isNull);
      expect(next.native(_notes, at(8, 6, 0)), isNull);
      expect(next.native(_notes, at(8, 22, 0)), _L.critical);
      expect(next.native(_notes, at(9, 0, 0)), _L.critical);
      expect(await access2.evaluate(_notes), AccessDecision.challenge);
    });
  });

  group('P11-M3 manual reductions through the bound protocol (SIMULATED)', () {
    test(
        'BR-A1 (§7C). deleting an activation rule: the proof is asked for '
        'EXACTLY the relaxed apps; probe, then ONE flag; profiles untouched',
        () async {
      final List<SmartRule> before = <SmartRule>[_act('guest')];
      final _Fx fx = await _Fx.create(rules: before);
      final int sends = fx.watcher.receivedPolicies.length;
      final List<Set<String>> seen = <Set<String>>[];
      final BoundRelaxationResult r = await fx.ruleReduction(
          before, const <SmartRule>[], SecurityProfileSet.defaults(),
          seen: seen);
      expect(r.status, BoundRelaxationStatus.applied);
      expect(seen, <Set<String>>[_protected]);
      final List<ProtectionPolicySnapshot?> sent =
          fx.watcher.receivedPolicies.sublist(sends);
      expect(sent, hasLength(2));
      expect(sent[0]!.authorizedRuleRelaxation, isFalse, reason: 'probe');
      expect(sent[1]!.authorizedRuleRelaxation, isTrue, reason: 'flag');
      expect(_t(sent[1]!.smartRules), isEmpty);
      expect(fx.native(_notes), isNull);
      expect(await fx.profiles(), SecurityProfileSet.defaults());
      expect(fx.watcher.authorizedPackages, isEmpty,
          reason: 'a relaxation grants nothing');
    });

    test(
        'BR-A2. a proof for fewer apps is refused: nothing flagged, still '
        'Critical', () async {
      final List<SmartRule> before = <SmartRule>[_act('guest')];
      final _Fx fx = await _Fx.create(rules: before);
      final BoundRelaxationResult r = await fx.ruleReduction(
        before,
        <SmartRule>[_act('guest', on: false)],
        SecurityProfileSet.defaults(),
        authorize: (Set<String> p) =>
            p.length == 1 && p.contains(_notes), // scoped to notes only
      );
      expect(r.status, BoundRelaxationStatus.denied);
      expect(fx.flagged, 0);
      expect(fx.native(_notes), _L.critical);
      expect(fx.native(_chat), _L.critical);
    });

    test(
        'BR-A3 (isolation). a profile change during a rule reduction is a '
        'conflict: the rule operation binds the profile set it used', () async {
      final List<SmartRule> before = <SmartRule>[_act('guest')];
      final _Fx fx = await _Fx.create(rules: before);
      expect(
        (await fx.c.securityProfiles.saveProfiles(
                SecurityProfileSet.defaults().withActive('home'),
                expected: SecurityProfileSet.defaults()))
            .isSuccess,
        isTrue,
      );
      final BoundRelaxationResult r = await fx.ruleReduction(
          before, const <SmartRule>[], SecurityProfileSet.defaults());
      expect(r.status, BoundRelaxationStatus.conflict);
      expect(fx.flagged, 0);
      expect(fx.native(_notes), _L.critical);
    });

    test(
        'BR-A4 (isolation). a rule proof never releases a HELD profile '
        'reduction: the probe is not applied → blocked, no flag', () async {
      final List<SmartRule> rules = <SmartRule>[_act('home')];
      final _Fx fx = await _Fx.create(
          rules: rules,
          profiles: SecurityProfileSet.defaults().withActive('guest'));
      // Guest → Normal written WITHOUT a proof: native holds Guest (union).
      expect(
        (await fx.c.securityProfiles.saveProfiles(SecurityProfileSet.defaults(),
                expected: SecurityProfileSet.defaults().withActive('guest')))
            .isSuccess,
        isTrue,
      );
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      expect(fx.native(_notes, _evening), _L.critical);

      // Retarget the (no-op Home) activation to Guest and back is not a
      // reduction; deleting a Guest activation is. Use Guest → disabled.
      final List<SmartRule> guestAct = <SmartRule>[_act('guest')];
      expect(
          (await fx.c.smartRules.replaceRules(guestAct, expected: rules))
              .isSuccess,
          isTrue);
      await fx.c.protectionBootstrap.synchronize();
      final int flaggedBefore = fx.flagged;
      final BoundRelaxationResult r = await fx.ruleReduction(guestAct,
          <SmartRule>[_act('guest', on: false)], SecurityProfileSet.defaults());
      expect(r.status, BoundRelaxationStatus.blocked);
      expect(fx.flagged, flaggedBefore);
      expect(fx.native(_notes, _evening), _L.critical,
          reason: 'the held manual Guest is still enforced');
    });

    test(
        'BR-A5 (R3). weakening a REFERENCED profile is a profile reduction '
        'for exactly the affected apps; rules are untouched', () async {
      final List<SmartRule> rules = <SmartRule>[_act(_tripId)];
      final _Fx fx =
          await _Fx.create(rules: rules, profiles: _withTrip(_L.critical));
      expect(fx.native(_notes), _L.critical);
      final List<Set<String>> seen = <Set<String>>[];
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: (Set<String> p) {
          seen.add(p);
          return true;
        },
        profilesBefore: _withTrip(_L.critical),
        profilesAfter: _withTrip(_L.sensitive),
        commit: () => fx.c.securityProfiles.saveProfiles(
          _withTrip(_L.sensitive),
          expected: _withTrip(_L.critical),
        ),
      );
      expect(r.status, BoundRelaxationStatus.applied);
      expect(seen, <Set<String>>[_protected]);
      expect(fx.native(_notes), _L.sensitive);
      expect(await fx.rules(), rules);
      expect(
          (await fx.profiles()).byId(_tripId)!.allProtectedLevel, _L.sensitive);
    });

    test(
        'BR-A6. the profile commit fails after native applied: raised back '
        'without a flag; documents unchanged; never claimed', () async {
      final List<SmartRule> rules = <SmartRule>[_act(_tripId)];
      final _Fx fx =
          await _Fx.create(rules: rules, profiles: _withTrip(_L.critical));
      fx.db.failProfileWrites = true;
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.profileChange,
        authorize: (Set<String> _) => true,
        profilesBefore: _withTrip(_L.critical),
        profilesAfter: _withTrip(_L.sensitive),
        commit: () => fx.c.securityProfiles.saveProfiles(
          _withTrip(_L.sensitive),
          expected: _withTrip(_L.critical),
        ),
      );
      expect(r.status, BoundRelaxationStatus.notApplied);
      final ProtectionPolicySnapshot last = fx.watcher.receivedPolicies.last!;
      expect(last.authorizedRuleRelaxation, isFalse);
      expect(fx.native(_notes), _L.critical);
      fx.db.failProfileWrites = false;
      expect(await fx.profiles(), _withTrip(_L.critical));
      expect(await fx.rules(), rules);
    });

    test(
        'BR-A7 (§7A). adding an activation is a raise: no proof, no flag, '
        'applied', () async {
      final _Fx fx = await _Fx.create();
      int asked = 0;
      expect(
          (await fx.c.smartRules.saveRule(_act('guest'), mustBeNew: true))
              .isSuccess,
          isTrue);
      final BoundRelaxationResult r =
          await fx.c.protectionBootstrap.applyBoundRelaxation(
        intent: BoundRelaxationIntent.ruleReduction,
        authorize: (Set<String> _) {
          asked++;
          return true;
        },
        rulesBefore: const <SmartRule>[],
        rulesAfter: <SmartRule>[_act('guest')],
        profilesBefore: SecurityProfileSet.defaults(),
        profilesAfter: SecurityProfileSet.defaults(),
        storageHoldsAfter: true,
      );
      expect(r.status, BoundRelaxationStatus.applied);
      expect(asked, 0);
      expect(fx.flagged, 0);
      expect(fx.native(_notes), _L.critical);
    });
  });
}
