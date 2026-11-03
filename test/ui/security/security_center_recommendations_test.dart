// Phase 9 / M3 — Security Center recommendations model and score integrity
// (PRODUCTION code, pure Dart).
//
// The real recommendation function and the real Security Score over real
// Phase 7 reports (ProtectionHealthEngine with explicit signals), the real
// Phase 8 catalog and real ProtectedApp records. SIMULATED: no Android
// device, native enforcement or OEM behaviour is observed.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/models/security_recommendation.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/protection/security_level_policy.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_recommendations.dart';
import 'package:smart_app_lock/ui/screens/security/security_score.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

typedef _L = AppSecurityLevel;
typedef _R = SecurityCenterRecommendations;

final DateTime t0 = DateTime(2026, 11, 3, 10);

// Exact catalog packages (Phase 8 / M2).
const String _wa = 'com.whatsapp'; // privacy → Sensitive
const String _ep = 'pk.com.telenor.phoenix'; // finance → Critical
const String _bw = 'com.x8bit.bitwarden'; // password manager → Critical
const String _notes = 'com.example.notes'; // not in the catalog

HealthSignals _signals({
  bool? configured = true,
  bool? credential = true,
  bool? apps = true,
  bool? overlay = true,
  bool overlayEver = true,
  bool? usage = true,
  bool? watcher = true,
  bool? restricted = false,
  bool? powerSave = false,
  bool? biometricEnabled = false,
  bool? biometricHardware = true,
  bool? biometricEnrolled = true,
}) =>
    HealthSignals(
      observedAt: t0,
      protectionConfigured: configured,
      credentialConfigured: credential,
      hasProtectedApps: apps,
      nativeProtectionEnabled: true,
      overlayGranted: overlay,
      overlayEverGranted: overlayEver,
      accessibilityEnabled: true,
      accessibilityEverGranted: true,
      accessibilityConnected: true,
      usageAccessGranted: usage,
      usageAccessEverGranted: true,
      nativeHealthAvailable: true,
      watcherRunning: watcher,
      shieldArmed: true,
      notificationsGranted: true,
      backgroundRestricted: restricted,
      sdkInt: 34,
      powerSaveMode: powerSave,
      biometricUnlockEnabled: biometricEnabled,
      biometricHardwarePresent: biometricHardware,
      biometricEnrolled: biometricEnrolled,
    );

ProtectionHealthReport _report(HealthSignals s, {DateTime? now}) =>
    ProtectionHealthEngine.evaluate(s, now: now ?? t0);

final ProtectionHealthReport secure = _report(_signals());
final ProtectionHealthReport attention = _report(_signals(usage: false));
final ProtectionHealthReport offline = _report(_signals(overlay: false));

ProtectedApp _app(String pkg, _L level, {String? label}) => ProtectedApp(
      packageName: pkg,
      label: label ?? 'Label $pkg',
      addedAt: DateTime(2026, 11, 1),
      securityLevel: level,
    );

SecurityScoreInputs _base({
  ProtectionHealthReport? health,
  Map<String, _L> apps = const <String, _L>{_notes: _L.standard},
  Map<String, _L>? native,
  Duration? grace = Duration.zero,
  ScoreSourceState appsState = ScoreSourceState.loaded,
  ScoreSourceState graceState = ScoreSourceState.loaded,
  bool checking = false,
  bool failed = false,
  bool useHealth = true,
}) {
  final Map<String, _L> confirmed = native ?? apps;
  return SecurityScoreInputs(
    appsState: appsState,
    apps: List<ProtectedApp>.unmodifiable(<ProtectedApp>[
      for (final MapEntry<String, _L> e in apps.entries) _app(e.key, e.value),
    ]),
    nativeLevelFor: (String pkg) => confirmed[pkg],
    graceState: graceState,
    grace: grace,
    health: useHealth ? (health ?? secure) : null,
    healthChecking: checking,
    healthFailed: failed,
  );
}

RecommendationsAssessment _assess(
  SecurityScoreInputs base, {
  Set<String>? dismissed = const <String>{},
}) =>
    _R.assess(RecommendationInputs(base: base, dismissed: dismissed));

List<String> _ids(RecommendationsAssessment a) =>
    a.items.map((SecurityCenterRecommendation r) => r.id).toList();

SecurityCenterRecommendation _item(RecommendationsAssessment a, String id) =>
    a.items.singleWhere((SecurityCenterRecommendation r) => r.id == id);

String _healthId(HealthIssueCode code, HealthComponent component) =>
    'health.${code.id}.${component.id}';

/// Every user-visible string of an assessment.
Iterable<String> _texts(RecommendationsAssessment a) sync* {
  for (final SecurityCenterRecommendation r in a.items) {
    yield r.title;
    yield r.reason;
    if (r.categoryLabel != null) yield r.categoryLabel!;
    for (final LevelSuggestion s in r.levels) {
      yield s.label;
      yield s.reason;
    }
  }
}

void main() {
  group('status: inputs must be readable (spec §2)', () {
    test('1. a failed or loading read never yields items (no stale list)', () {
      final Map<String, RecommendationsAssessment> cases =
          <String, RecommendationsAssessment>{
        'apps failed':
            _assess(_base(health: offline, appsState: ScoreSourceState.failed)),
        'apps loading': _assess(_base(appsState: ScoreSourceState.loading)),
        'grace failed': _assess(_base(graceState: ScoreSourceState.failed)),
        'grace null': _assess(_base(grace: null)),
        'grace loading': _assess(_base(graceState: ScoreSourceState.loading)),
        'health checking': _assess(_base(useHealth: false, checking: true)),
        'health failed': _assess(_base(useHealth: false, failed: true)),
        'never checked': _assess(_base(useHealth: false)),
      };
      final Map<String, RecommendationsStatus> status =
          <String, RecommendationsStatus>{
        for (final MapEntry<String, RecommendationsAssessment> e
            in cases.entries)
          e.key: e.value.status,
      };
      expect(status, <String, RecommendationsStatus>{
        'apps failed': RecommendationsStatus.unavailable,
        'apps loading': RecommendationsStatus.assessing,
        'grace failed': RecommendationsStatus.unavailable,
        'grace null': RecommendationsStatus.unavailable,
        'grace loading': RecommendationsStatus.assessing,
        'health checking': RecommendationsStatus.assessing,
        'health failed': RecommendationsStatus.unavailable,
        'never checked': RecommendationsStatus.unavailable,
      });
      for (final MapEntry<String, RecommendationsAssessment> e
          in cases.entries) {
        expect(e.value.items, isEmpty, reason: e.key);
        expect(e.value.allClear, isFalse, reason: e.key);
      }
      expect(cases['apps failed']!.reason,
          RecommendationsUnavailableReason.appsUnreadable);
      expect(cases['grace failed']!.reason,
          RecommendationsUnavailableReason.settingsUnreadable);
      expect(cases['health failed']!.reason,
          RecommendationsUnavailableReason.healthFailed);
      expect(cases['never checked']!.reason,
          RecommendationsUnavailableReason.healthNotChecked);
    });

    test(
        '2. healthy configuration: no artificial recommendation, a calm '
        'all-clear (advisories never recommended)', () {
      final RecommendationsAssessment a = _assess(_base(apps: <String, _L>{
        _notes: _L.standard,
        _ep: _L.critical,
        _wa: _L.sensitive,
      }));
      expect(a.status, RecommendationsStatus.ready);
      expect(a.items, isEmpty);
      expect(a.allClear, isTrue);
      // Battery Saver on and fingerprint unavailable / not enrolled are
      // Phase 7 advisories: still nothing is recommended.
      for (final HealthSignals s in <HealthSignals>[
        _signals(powerSave: true),
        _signals(biometricEnabled: true, biometricEnrolled: false),
        _signals(biometricEnabled: true, biometricHardware: false),
      ]) {
        final ProtectionHealthReport r = _report(s);
        expect(r.state, ProtectionHealthState.secure);
        expect(r.issues, isNotEmpty); // the advisory exists...
        final RecommendationsAssessment b = _assess(_base(health: r));
        expect(b.items, isEmpty); // ...but is never recommended
        expect(b.allClear, isTrue);
      }
    });
  });

  group('A. setup vs a protection failure', () {
    test(
        '3. first-time setup: PIN/pattern and apps steps only, worded as '
        'setup, never as a failure', () {
      final ProtectionHealthReport notSetUp =
          _report(_signals(configured: false, credential: false, apps: false));
      expect(notSetUp.state, ProtectionHealthState.protectionOffline);
      final RecommendationsAssessment a = _assess(
        _base(
            health: notSetUp,
            apps: const <String, _L>{},
            grace: const Duration(minutes: 5)),
      );
      expect(_ids(a), <String>[_R.setupCredentialId, _R.setupAppsId]);
      for (final SecurityCenterRecommendation r in a.items) {
        expect(r.priority, RecommendationPriority.setup);
        expect(r.dismissible, isFalse);
      }
      expect(_item(a, _R.setupCredentialId).action,
          RecommendationAction.showAuthentication);
      expect(_item(a, _R.setupAppsId).action, RecommendationAction.openApps);
      final String all = _texts(a).join(' ').toLowerCase();
      for (final String failure in <String>[
        'offline',
        'fail',
        'not working',
        'turned off',
        'stopped',
        'without a lock',
      ]) {
        expect(all.contains(failure), isFalse, reason: failure);
      }
      expect(a.allClear, isFalse);
    });

    test(
        '4. PIN set, no apps (the user\'s choice): only "Choose apps"; no '
        'health, level or re-lock items', () {
      final ProtectionHealthReport noApps =
          _report(_signals(configured: false, apps: false));
      final RecommendationsAssessment a = _assess(_base(
        health: noApps,
        apps: const <String, _L>{},
        grace: const Duration(minutes: 5),
      ));
      expect(_ids(a), <String>[_R.setupAppsId]);
      expect(_item(a, _R.setupAppsId).title, _R.setupAppsTitle);
    });

    test(
        '4b. apps protected but no PIN/pattern (setup unfinished): only the '
        'PIN step; no level or re-lock items until setup is finished', () {
      final ProtectionHealthReport noCredential =
          _report(_signals(configured: false, credential: false));
      expect(
        noCredential.issues
            .map((HealthIssue i) => i.code)
            .contains(HealthIssueCode.protectionNotConfigured),
        isTrue,
      );
      for (final Set<String>? dismissed in <Set<String>?>[
        const <String>{},
        null,
      ]) {
        final RecommendationsAssessment a = _assess(
          _base(
            health: noCredential,
            apps: const <String, _L>{_wa: _L.standard, _notes: _L.standard},
            grace: const Duration(minutes: 5),
          ),
          dismissed: dismissed,
        );
        expect(_ids(a), <String>[_R.setupCredentialId], reason: '$dismissed');
        expect(a.optionalUnavailable, isFalse,
            reason: 'nothing optional is due during setup');
        expect(a.allClear, isFalse);
      }
    });

    test(
        '5. a configured user who never allowed the overlay: a protection '
        'item worded as setup (Phase 7 category), not as a breakdown', () {
      final ProtectionHealthReport r =
          _report(_signals(overlay: false, overlayEver: false));
      final RecommendationsAssessment a = _assess(_base(health: r));
      final SecurityCenterRecommendation item = a.items.first;
      expect(
          item.id,
          _healthId(
              HealthIssueCode.overlayUnavailable, HealthComponent.overlay));
      expect(item.priority, RecommendationPriority.protection);
      expect(item.categoryLabel, 'Setup needed');
      expect(item.title, 'Display over other apps is not allowed yet');
      expect(item.title.toLowerCase(), isNot(contains('turned off')));
    });
  });

  group('B. genuine health issues (Phase 7 ids, wording, repairs)', () {
    test(
        '6. OFFLINE (overlay revoked): a protection item with the Phase 7 '
        'title, explanation, category and Health Details', () {
      final RecommendationsAssessment a = _assess(_base(health: offline));
      final HealthIssue issue = offline.issues.first;
      final HealthIssueView view = HealthPresentation.issue(issue);
      final SecurityCenterRecommendation item = a.items.first;
      expect(
          item.id,
          _healthId(
              HealthIssueCode.overlayUnavailable, HealthComponent.overlay));
      expect(item.kind, RecommendationKind.health);
      expect(item.priority, RecommendationPriority.protection);
      expect(item.title, view.title);
      expect(item.title, 'Display over other apps was turned off');
      expect(item.reason, view.explanation);
      expect(item.categoryLabel, view.categoryLabel);
      expect(item.action, RecommendationAction.openHealthDetails);
      expect(item.healthIssue, same(issue));
      expect(item.source, 'health:overlay_unavailable/revoked');
      expect(item.dismissible, isFalse);
      expect(a.allClear, isFalse);
    });

    test(
        '7. ATTENTION issues: Usage Access, watcher stopped and background '
        'restriction map to attention items; nothing beyond Phase 7', () {
      final Map<String, (HealthSignals, HealthIssueCode)> cases =
          <String, (HealthSignals, HealthIssueCode)>{
        'usage': (
          _signals(usage: false),
          HealthIssueCode.usageAccessUnavailable
        ),
        'watcher': (
          _signals(watcher: false),
          HealthIssueCode.watcherNotRunning
        ),
        'restricted': (
          _signals(restricted: true),
          HealthIssueCode.backgroundRestricted
        ),
      };
      for (final MapEntry<String, (HealthSignals, HealthIssueCode)> e
          in cases.entries) {
        final ProtectionHealthReport r = _report(e.value.$1);
        final RecommendationsAssessment a = _assess(_base(health: r));
        final List<HealthIssue> actionable = r.issues
            .where(
                (HealthIssue i) => i.severity != HealthIssueSeverity.advisory)
            .toList();
        // Exactly the report's actionable issues, in the engine's order.
        expect(
          _ids(a),
          <String>[for (final HealthIssue i in actionable) _R.healthId(i)],
          reason: e.key,
        );
        expect(
          a.items.map((SecurityCenterRecommendation x) => x.healthIssue!.code),
          contains(e.value.$2),
          reason: e.key,
        );
        for (final SecurityCenterRecommendation x in a.items) {
          expect(
            x.priority,
            x.healthIssue!.severity == HealthIssueSeverity.offline
                ? RecommendationPriority.protection
                : RecommendationPriority.attention,
          );
        }
      }
      // Background restriction: the Phase 7 repair (Health Details, with
      // its OEM guidance); no invented fix.
      final RecommendationsAssessment bg =
          _assess(_base(health: _report(_signals(restricted: true))));
      expect(bg.items.single.action, RecommendationAction.openHealthDetails);
      expect(
        bg.items.single.title,
        'Android restricts Smart App Lock in the background',
      );
    });

    test(
        '8. a stale report lists only "Status is out of date" with Check '
        'again; earlier issues are not repeated as current', () {
      final ProtectionHealthReport stale = _report(
        _signals(overlay: false, usage: false),
        now: t0.add(const Duration(seconds: 31)),
      );
      expect(stale.stale, isTrue);
      final RecommendationsAssessment a =
          _assess(_base(health: stale, grace: const Duration(minutes: 5)));
      final List<SecurityCenterRecommendation> health = a.items
          .where((SecurityCenterRecommendation r) =>
              r.kind == RecommendationKind.health)
          .toList();
      expect(health.map((SecurityCenterRecommendation r) => r.id), <String>[
        _healthId(
            HealthIssueCode.healthSnapshotStale, HealthComponent.nativeHealth),
      ]);
      expect(health.single.action, RecommendationAction.checkAgain);
      expect(a.healthStale, isTrue);
      expect(a.allClear, isFalse);
      // A stale SECURE report is never all-clear either.
      final RecommendationsAssessment b = _assess(_base(
        health: _report(_signals(), now: t0.add(const Duration(minutes: 2))),
      ));
      expect(b.allClear, isFalse);
      expect(b.items.single.action, RecommendationAction.checkAgain);
    });

    test('9. the action follows the Phase 7 repair kind for every issue', () {
      for (final HealthSignals s in <HealthSignals>[
        _signals(overlay: false),
        _signals(usage: false),
        _signals(watcher: false),
        _signals(restricted: true),
        _signals(overlay: null),
        _signals(usage: null, watcher: null),
      ]) {
        final ProtectionHealthReport r = _report(s);
        for (final SecurityCenterRecommendation item
            in _assess(_base(health: r)).items) {
          final HealthRepairKind kind =
              HealthPresentation.issue(item.healthIssue!).repair.kind;
          expect(
            item.action,
            kind == HealthRepairKind.checkAgain
                ? RecommendationAction.checkAgain
                : RecommendationAction.openHealthDetails,
            reason: item.id,
          );
        }
      }
    });
  });

  group('C. security levels (Phase 8 exact-package catalog)', () {
    test(
        '10. exact packages only: current and suggested level, catalog '
        'reason, one grouped item', () {
      final RecommendationsAssessment a = _assess(_base(apps: <String, _L>{
        _wa: _L.standard,
        _notes: _L.standard,
        _ep: _L.sensitive,
        _bw: _L.critical,
      }));
      final SecurityCenterRecommendation item = _item(a, _R.levelsId);
      expect(item.priority, RecommendationPriority.optional);
      expect(item.action, RecommendationAction.openApps);
      expect(item.title, _R.levelsTitle(2));
      expect(item.levels.map((LevelSuggestion s) => s.packageName),
          <String>[_wa, _ep]);
      final LevelSuggestion wa = item.levels.first;
      expect(wa.current, _L.standard);
      expect(wa.suggested, _L.sensitive);
      expect(wa.label, 'Label $_wa');
      expect(wa.reason, SensitiveAppCategory.privacy.reason);
      expect(wa.dismissalKey, '$_wa@sensitive');
      final LevelSuggestion ep = item.levels[1];
      expect((ep.current, ep.suggested), (_L.sensitive, _L.critical));
      expect(item.dismissalKeys, <String>['$_wa@sensitive', '$_ep@critical']);
    });

    test(
        '11. unsupported classifications get nothing (no keyword or label '
        'matching, already at the level, near-miss package names)', () {
      final RecommendationsAssessment a = _assess(_base(apps: <String, _L>{
        _notes: _L.standard,
        'com.whatsapp.w4b': _L.standard,
        'com.example.bank': _L.standard,
        'COM.WHATSAPP': _L.standard,
        _wa: _L.sensitive,
        _ep: _L.critical,
      }));
      expect(_ids(a), isNot(contains(_R.levelsId)));
    });

    test(
        '12. the Apps tab rule: the stricter of saved and native; a held '
        'stricter level suppresses the hint; matches forApp exactly', () {
      // Saved Standard, native still Critical (pending downgrade): no hint.
      final RecommendationsAssessment held = _assess(_base(
        apps: <String, _L>{_ep: _L.standard},
        native: <String, _L>{_ep: _L.critical},
      ));
      expect(_ids(held), isNot(contains(_R.levelsId)));
      // Exhaustive agreement with SecurityRecommendations.forApp.
      for (final String pkg in <String>[_wa, _ep, _notes]) {
        for (final _L saved in _L.values) {
          for (final _L? native in <_L?>[null, ..._L.values]) {
            final RecommendationsAssessment a = _assess(_base(
              apps: <String, _L>{pkg: saved},
              native: <String, _L>{if (native != null) pkg: native},
            ));
            final SecurityRecommendation? expected =
                SecurityRecommendations.forApp(
              pkg,
              native == null
                  ? saved
                  : SecurityLevelPolicy.stricter(saved, native),
            );
            final List<LevelSuggestion> got = a.items
                .where((SecurityCenterRecommendation r) => r.id == _R.levelsId)
                .expand((SecurityCenterRecommendation r) => r.levels)
                .toList();
            expect(got.length, expected == null ? 0 : 1,
                reason: '$pkg $saved $native');
            if (expected != null) {
              expect(got.single.suggested, expected.level);
              expect(got.single.current, saved);
            }
          }
        }
      }
    });

    test(
        '13. dismissal preferences are honoured exactly (package@level) and '
        'an unreadable set shows no optional item', () {
      final SecurityScoreInputs base = _base(
        apps: <String, _L>{_wa: _L.standard, _ep: _L.standard},
        grace: const Duration(minutes: 1),
      );
      final RecommendationsAssessment some =
          _assess(base, dismissed: <String>{'$_wa@sensitive'});
      expect(
        _item(some, _R.levelsId)
            .levels
            .map((LevelSuggestion s) => s.packageName),
        <String>[_ep],
      );
      // A dismissal of another level never hides a different suggestion.
      final RecommendationsAssessment other =
          _assess(base, dismissed: <String>{'$_wa@critical'});
      expect(_item(other, _R.levelsId).levels, hasLength(2));
      // Unreadable dismissals: optional items are not re-shown.
      final RecommendationsAssessment unknown = _assess(base, dismissed: null);
      expect(_ids(unknown), isEmpty);
      expect(unknown.optionalUnavailable, isTrue);
      expect(unknown.allClear, isFalse);
      // ...but genuine health items are still listed.
      final RecommendationsAssessment withHealth = _assess(
        _base(health: offline, apps: <String, _L>{_wa: _L.standard}),
        dismissed: null,
      );
      expect(withHealth.items.first.kind, RecommendationKind.health);
    });
  });

  group('D. re-lock (SecurityLevelPolicy, the Security tab options)', () {
    test('14. the choices and labels are exactly the Security tab options', () {
      expect(
        _R.relockChoices,
        SecurityScreen.graceOptions.map(((String, Duration) o) => o.$2),
      );
      for (final (String, Duration) o in SecurityScreen.graceOptions) {
        expect(_R.durationLabel(o.$2), o.$1);
      }
    });

    test(
        '15. proposal = the longest shorter option that shortens some app\'s '
        'effective grace; never when nothing would change', () {
      RelockSuggestion? relock(Map<String, _L> apps, Duration grace,
              {Map<String, _L>? native}) =>
          _assess(_base(apps: apps, grace: grace, native: native))
              .items
              .where((SecurityCenterRecommendation r) => r.id == _R.relockId)
              .map((SecurityCenterRecommendation r) => r.relock)
              .firstOrNull;

      final RelockSuggestion five = relock(
          <String, _L>{_notes: _L.standard}, const Duration(minutes: 5))!;
      expect(five.current, const Duration(minutes: 5));
      expect(five.suggested, const Duration(minutes: 1));
      expect(five.longestNow, const Duration(minutes: 5));
      expect(five.longestAfter, const Duration(minutes: 1));
      expect(five.affectedApps, 1);

      final RelockSuggestion thirty = relock(
          <String, _L>{_notes: _L.standard}, const Duration(seconds: 30))!;
      expect(thirty.suggested, Duration.zero);

      // Only Sensitive apps (15 s cap): 1 min / 30 s change nothing.
      final RelockSuggestion sensitive =
          relock(<String, _L>{_wa: _L.sensitive}, const Duration(minutes: 5))!;
      expect(sensitive.suggested, Duration.zero);
      expect(sensitive.longestNow, const Duration(seconds: 15));

      // Immediate already, or only (confirmed) Critical apps: nothing.
      expect(relock(<String, _L>{_notes: _L.standard}, Duration.zero), isNull);
      expect(relock(<String, _L>{_ep: _L.critical}, const Duration(minutes: 5)),
          isNull);
      // An unconfirmed Critical level is not assumed (score's rule).
      expect(
        relock(<String, _L>{_ep: _L.critical}, const Duration(minutes: 5),
                native: const <String, _L>{})!
            .affectedApps,
        1,
      );
      final SecurityCenterRecommendation item = _item(
        _assess(_base(grace: const Duration(minutes: 5))),
        _R.relockId,
      );
      expect(item.action, RecommendationAction.showRelock);
      expect(item.priority, RecommendationPriority.optional);
      expect(item.dismissalKeys, <String>['#relock@300']);
      expect(item.reason, contains('This is optional.'));
    });

    test('16. a re-lock dismissal is bound to the current setting', () {
      final Set<String> dismissed = <String>{
        _R.relockDismissalKey(
          const Duration(minutes: 5),
        )
      };
      expect(
        _ids(_assess(_base(grace: const Duration(minutes: 5)),
            dismissed: dismissed)),
        isEmpty,
      );
      expect(
        _ids(_assess(_base(grace: const Duration(minutes: 1)),
            dismissed: dismissed)),
        <String>[_R.relockId],
      );
    });
  });

  group('priority and integrity', () {
    test(
        '17. order: protection problems, attention, setup, then optional '
        '(levels before re-lock)', () {
      final ProtectionHealthReport both =
          _report(_signals(overlay: false, usage: false));
      final RecommendationsAssessment a = _assess(_base(
        health: both,
        apps: <String, _L>{_wa: _L.standard},
        grace: const Duration(minutes: 5),
      ));
      final List<RecommendationPriority> order =
          a.items.map((SecurityCenterRecommendation r) => r.priority).toList();
      expect(order, <RecommendationPriority>[
        ...order.where((RecommendationPriority p) =>
            p == RecommendationPriority.protection),
        ...order.where((RecommendationPriority p) =>
            p == RecommendationPriority.attention),
        RecommendationPriority.optional,
        RecommendationPriority.optional,
      ]);
      expect(order.first, RecommendationPriority.protection);
      expect(order, contains(RecommendationPriority.attention));
      expect(_ids(a).sublist(_ids(a).length - 2),
          <String>[_R.levelsId, _R.relockId]);
      // Every id is unique and stable across identical inputs.
      expect(_ids(a).toSet(), hasLength(_ids(a).length));
      expect(
          _ids(_assess(_base(
            health: both,
            apps: <String, _L>{_wa: _L.standard},
            grace: const Duration(minutes: 5),
          ))),
          _ids(a));
    });

    test(
        '18. dismissing never changes the score; the score moves only with '
        'refreshed source data', () {
      final SecurityScoreInputs base = _base(
        apps: <String, _L>{_wa: _L.standard, _notes: _L.standard},
        grace: const Duration(minutes: 5),
      );
      final SecurityScoreAssessment before = SecurityScore.assess(base);
      final RecommendationsAssessment recs = _assess(base);
      final Set<String> all = <String>{
        for (final SecurityCenterRecommendation r in recs.items)
          ...r.dismissalKeys,
      };
      final RecommendationsAssessment afterDismiss =
          _assess(base, dismissed: all);
      expect(afterDismiss.items, isEmpty);
      // The score has no dismissal input: identical before and after.
      final SecurityScoreAssessment after = SecurityScore.assess(base);
      expect(after.points, before.points);
      expect(before.points, 60 + 10); // 5 min: credit 1 + 1 → floor(40×2/8)
      // Accepting the re-lock suggestion only counts once the setting is
      // actually saved and read again.
      final Duration proposed = _item(recs, _R.relockId).relock!.suggested;
      final SecurityScoreAssessment reread = SecurityScore.assess(_base(
        apps: <String, _L>{_wa: _L.standard, _notes: _L.standard},
        grace: proposed,
      ));
      expect(reread.points, greaterThan(before.points!));
      expect(reread.points, 60 + 20); // 1 min: credit 2 + 2
    });

    test('19. no premium, paywall, purchase or urgency wording in any state',
        () {
      final List<RecommendationsAssessment> all = <RecommendationsAssessment>[
        for (final ProtectionHealthReport r in <ProtectionHealthReport>[
          secure,
          attention,
          offline,
          _report(_signals(restricted: true, watcher: false)),
          _report(_signals(configured: false, credential: false, apps: false)),
          _report(_signals(), now: t0.add(const Duration(minutes: 1))),
        ])
          for (final Duration g in _R.relockChoices)
            _assess(_base(
              health: r,
              apps: <String, _L>{_wa: _L.standard, _ep: _L.standard},
              grace: g,
            )),
      ];
      final String text = all.expand(_texts).join(' | ').toLowerCase();
      expect(text, isNotEmpty);
      for (final String banned in <String>[
        'premium',
        'upgrade',
        'subscri',
        'purchase',
        'buy',
        'paywall',
        'pro version',
        'unlock all',
        'ad-free',
        'limited time',
        'hurry',
        'act now',
        'urgent',
        'immediately',
        'warning!',
        '!',
        '100%',
        'guarantee',
        'unhackable',
        'perfect',
        'fingerprint',
        'battery saver',
      ]) {
        expect(text.contains(banned), isFalse, reason: banned);
      }
    });

    test('20. pure: inputs are not mutated and results are unmodifiable', () {
      final SecurityScoreInputs base = _base(
        health: offline,
        apps: <String, _L>{_wa: _L.standard},
        grace: const Duration(minutes: 5),
      );
      final Set<String> dismissed = <String>{'x@critical'};
      final RecommendationsAssessment a = _assess(base, dismissed: dismissed);
      expect(dismissed, <String>{'x@critical'});
      expect(base.apps.single.securityLevel, _L.standard);
      expect(() => a.items.add(a.items.first), throwsUnsupportedError);
      expect(
          () => _item(a, _R.levelsId).levels.clear(), throwsUnsupportedError);
    });
  });

  group('score integrity QA (PRD "Score Integrity QA", 9H)', () {
    test(
        '21. over every state × grace × level: SECURE ≥ 60, ATTENTION ≤ 40 '
        'and provisional, OFFLINE / stale withheld; the breakdown sums '
        'exactly', () {
      final ProtectionHealthReport stale =
          _report(_signals(), now: t0.add(const Duration(minutes: 1)));
      for (final _L a in _L.values) {
        for (final _L b in _L.values) {
          for (final Duration g in _R.relockChoices) {
            SecurityScoreAssessment s(ProtectionHealthReport r) =>
                SecurityScore.assess(_base(
                  health: r,
                  apps: <String, _L>{_notes: a, _wa: b},
                  grace: g,
                ));
            final SecurityScoreAssessment ok = s(secure);
            expect(ok.status, SecurityScoreStatus.available);
            expect(ok.points, ok.healthEarned! + ok.relockEarned!);
            expect(ok.points, inInclusiveRange(60, 100));
            final SecurityScoreAssessment att = s(attention);
            expect(att.status, SecurityScoreStatus.provisional);
            expect(att.healthEarned, 0);
            expect(att.points, att.relockEarned);
            expect(att.points, lessThanOrEqualTo(40));
            expect(s(offline).status, SecurityScoreStatus.withheldOffline);
            expect(s(offline).points, isNull);
            expect(s(stale).status, SecurityScoreStatus.unavailable);
            expect(s(stale).points, isNull);
          }
        }
      }
    });

    test(
        '22. unconfirmed levels never earn more than confirmed; app count, '
        'biometrics and advisories do not move the score; 100 is reachable '
        'without biometrics', () {
      for (final _L saved in _L.values) {
        final int confirmed = SecurityScore.assess(_base(
          apps: <String, _L>{_ep: saved},
          grace: const Duration(minutes: 5),
        )).points!;
        for (final _L? native in <_L?>[null, ..._L.values]) {
          final int got = SecurityScore.assess(_base(
            apps: <String, _L>{_ep: saved},
            native: <String, _L>{if (native != null) _ep: native},
            grace: const Duration(minutes: 5),
          )).points!;
          expect(got, lessThanOrEqualTo(confirmed), reason: '$saved/$native');
        }
      }
      int points(Map<String, _L> apps, {ProtectionHealthReport? r}) =>
          SecurityScore.assess(_base(
            health: r,
            apps: apps,
            grace: const Duration(seconds: 30),
          )).points!;
      expect(
        points(<String, _L>{
          for (int i = 0; i < 10; i++) 'com.example.app$i': _L.standard,
        }),
        points(<String, _L>{_notes: _L.standard}),
      );
      final int base = points(<String, _L>{_notes: _L.standard});
      for (final HealthSignals s in <HealthSignals>[
        _signals(biometricEnabled: true, biometricHardware: false),
        _signals(biometricEnabled: true, biometricEnrolled: false),
        _signals(powerSave: true),
      ]) {
        expect(points(<String, _L>{_notes: _L.standard}, r: _report(s)), base);
      }
      expect(
        SecurityScore.assess(_base(
          health: _report(_signals(biometricEnabled: false)),
          apps: <String, _L>{_notes: _L.standard},
        )).points,
        SecurityScore.maxPoints,
      );
    });
  });
}
