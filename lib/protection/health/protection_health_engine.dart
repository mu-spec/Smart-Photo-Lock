/// Phase 7 / Milestone 1 — Protection Health engine (pure, deterministic).
///
/// The engine turns one [HealthSignals] observation into a
/// [ProtectionHealthReport]:
///
///  * three overall states — SECURE, ATTENTION REQUIRED, PROTECTION OFFLINE;
///  * per-component statuses that distinguish an intentional choice
///    (`disabledByUser`) from never set up, revoked, not running, restricted,
///    unsupported and UNKNOWN;
///  * machine-readable issues with a stable id, severity, cause and a repair
///    action hint for the Phase 7 / M2 dashboard (metadata only — the engine
///    never performs an action).
///
/// Precedence (deterministic): any `offline` issue → PROTECTION OFFLINE;
/// otherwise any `attention` issue → ATTENTION REQUIRED; otherwise SECURE.
/// `advisory` issues never change the state. SECURE therefore requires every
/// core signal to be POSITIVELY observed in a fresh snapshot: an UNKNOWN or
/// stale core signal always yields at least ATTENTION REQUIRED. Saved
/// configuration alone and the Flutter heartbeat are never evidence of
/// health.
///
/// SECURE means every observable protection component was positively seen
/// working in a fresh snapshot. It is NOT a guarantee against every Android
/// bypass, OEM behaviour or unobservable state (see [HealthLimitation]).
///
/// The engine is observational: it cannot grant access, clear a ticket,
/// reset a lockout, change a permission or start/stop a component.
library;

/// Overall Protection Health.
enum ProtectionHealthState {
  secure('SECURE'),
  attentionRequired('ATTENTION_REQUIRED'),
  protectionOffline('PROTECTION_OFFLINE');

  const ProtectionHealthState(this.id);

  /// Stable machine-readable identifier.
  final String id;
}

/// The monitored parts of protection.
enum HealthComponent {
  protectionConfiguration('protection_configuration'),

  /// The native enforcement switch (`ProtectionStateStore.isEnabled`) that
  /// the shield, recovery and watcher actually consult.
  nativeEnforcement('native_enforcement'),
  overlay('overlay'),
  accessibilityDetection('accessibility_detection'),
  usageAccessDetection('usage_access_detection'),
  watcher('watcher'),
  shield('shield'),
  notifications('notifications'),
  backgroundRestriction('background_restriction'),
  oemBackgroundControls('oem_background_controls'),
  batterySaver('battery_saver'),
  biometric('biometric'),
  nativeHealth('native_health');

  const HealthComponent(this.id);
  final String id;
}

/// Status of one component.
enum ComponentStatus {
  /// Positively observed working.
  operational('operational'),

  /// Intentionally off by the user's own app choice (not a fault).
  disabledByUser('disabled_by_user'),

  /// Never granted / never set up on this device.
  notSetUp('not_set_up'),

  /// Granted before (per grant history), missing now.
  revoked('revoked'),

  /// Enabled/expected but not currently running (OEM kill, crash, stop).
  notRunning('not_running'),

  /// Limited by an Android power/background restriction.
  restricted('restricted'),

  /// Not available on this device or API level.
  unsupported('unsupported'),

  /// Could not be observed reliably.
  unknown('unknown');

  const ComponentStatus(this.id);
  final String id;
}

enum HealthIssueSeverity {
  /// Core protection is unavailable.
  offline('offline'),

  /// Protection is reduced or cannot be confirmed.
  attention('attention'),

  /// Informational; never changes the overall state.
  advisory('advisory');

  const HealthIssueSeverity(this.id);
  final String id;
}

enum HealthCause {
  /// No app credential yet: first-time setup is incomplete (not a fault).
  setupIncomplete('setup_incomplete'),

  /// A credential exists but no app is protected: the user's own choice
  /// (this app has no other "pause protection" switch).
  noProtectedApps('no_protected_apps'),
  userChoice('user_choice'),
  notGranted('not_granted'),
  revoked('revoked'),
  notRunning('not_running'),
  restricted('restricted'),
  notEnrolled('not_enrolled'),
  unsupported('unsupported'),
  unknown('unknown'),
  stale('stale');

  const HealthCause(this.id);
  final String id;
}

/// Coarse wording class for a UI, derived from severity and cause. Only
/// [interrupted] describes something Android/OEM/the app stopped on its own;
/// setup and user choices must never be worded as a system failure.
enum HealthIssueCategory {
  setup('setup'),
  userChoice('user_choice'),
  revoked('revoked'),
  interrupted('interrupted'),
  restricted('restricted'),
  uncertain('uncertain'),
  advisory('advisory');

  const HealthIssueCategory(this.id);
  final String id;

  bool get isSystemFailure => this == HealthIssueCategory.interrupted;
}

/// Repair hint for a future UI. Metadata only: nothing here is invoked by
/// the engine or the monitor, and biometric enrollment is user-initiated.
enum HealthRepairAction {
  configureProtection('configure_protection'),
  chooseProtectedApps('choose_protected_apps'),
  openOverlaySettings('open_overlay_settings'),
  openAccessibilitySettings('open_accessibility_settings'),
  openUsageAccessSettings('open_usage_access_settings'),
  openNotificationSettings('open_notification_settings'),
  openAppBatterySettings('open_app_battery_settings'),
  openBatterySaverSettings('open_battery_saver_settings'),
  openBiometricSettings('open_biometric_settings'),
  openSmartAppLock('open_smart_app_lock'),
  refresh('refresh');

  const HealthRepairAction(this.id);
  final String id;
}

/// Stable issue identifiers. Severity is fixed per code.
enum HealthIssueCode {
  protectionNotConfigured(
    'protection_not_configured',
    HealthIssueSeverity.offline,
  ),
  enforcementNotArmed(
    'enforcement_not_armed',
    HealthIssueSeverity.offline,
  ),
  overlayUnavailable('overlay_unavailable', HealthIssueSeverity.offline),
  detectionOffline('detection_offline', HealthIssueSeverity.offline),
  accessibilityUnavailable(
    'accessibility_unavailable',
    HealthIssueSeverity.attention,
  ),
  accessibilityNotRunning(
    'accessibility_not_running',
    HealthIssueSeverity.attention,
  ),
  usageAccessUnavailable(
    'usage_access_unavailable',
    HealthIssueSeverity.attention,
  ),
  watcherNotRunning('watcher_not_running', HealthIssueSeverity.attention),
  shieldNotArmed('shield_not_armed', HealthIssueSeverity.attention),
  notificationsDisabled(
    'notifications_disabled',
    HealthIssueSeverity.attention,
  ),
  backgroundRestricted('background_restricted', HealthIssueSeverity.attention),
  signalUnknown('signal_unknown', HealthIssueSeverity.attention),
  healthSnapshotStale('health_snapshot_stale', HealthIssueSeverity.attention),
  batterySaverOn('battery_saver_on', HealthIssueSeverity.advisory),
  biometricUnavailable('biometric_unavailable', HealthIssueSeverity.advisory);

  const HealthIssueCode(this.id, this.severity);
  final String id;
  final HealthIssueSeverity severity;
}

/// One machine-readable health issue.
class HealthIssue {
  const HealthIssue({
    required this.code,
    required this.component,
    required this.cause,
    this.action,
    this.detail = const <String, String>{},
  });

  final HealthIssueCode code;
  final HealthComponent component;
  final HealthCause cause;
  final HealthRepairAction? action;

  /// Non-secret context (component statuses, API level, native error text).
  final Map<String, String> detail;

  HealthIssueSeverity get severity => code.severity;

  HealthIssueCategory get category {
    if (severity == HealthIssueSeverity.advisory) {
      return HealthIssueCategory.advisory;
    }
    return switch (cause) {
      HealthCause.setupIncomplete ||
      HealthCause.notGranted =>
        HealthIssueCategory.setup,
      HealthCause.noProtectedApps ||
      HealthCause.userChoice =>
        HealthIssueCategory.userChoice,
      HealthCause.revoked => HealthIssueCategory.revoked,
      HealthCause.notRunning => HealthIssueCategory.interrupted,
      HealthCause.restricted => HealthIssueCategory.restricted,
      HealthCause.unknown ||
      HealthCause.stale ||
      HealthCause.notEnrolled ||
      HealthCause.unsupported =>
        HealthIssueCategory.uncertain,
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': code.id,
        'severity': severity.id,
        'component': component.id,
        'cause': cause.id,
        'category': category.id,
        'action': action?.id,
        if (detail.isNotEmpty) 'detail': Map<String, String>.of(detail),
      };

  @override
  String toString() => '${code.id}(${component.id}/${cause.id})';
}

/// Raw observations for one health evaluation. `null` = UNKNOWN (the
/// signal could not be read, the API is unsupported, or it timed out).
class HealthSignals {
  const HealthSignals({
    required this.observedAt,
    required this.protectionConfigured,
    required this.overlayGranted,
    required this.accessibilityEnabled,
    required this.usageAccessGranted,
    required this.nativeHealthAvailable,
    this.credentialConfigured,
    this.hasProtectedApps,
    this.nativeProtectionEnabled,
    this.overlayEverGranted = false,
    this.accessibilityEverGranted = false,
    this.usageAccessEverGranted = false,
    this.accessibilityConnected,
    this.watcherRunning,
    this.watcherLastError,
    this.shieldArmed,
    this.notificationsGranted,
    this.backgroundRestricted,
    this.sdkInt,
    this.powerSaveMode,
    this.ignoringBatteryOptimizations,
    this.biometricUnlockEnabled,
    this.biometricHardwarePresent,
    this.biometricEnrolled,
  });

  /// When the observation STARTED (the conservative age reference).
  final DateTime observedAt;

  /// From the authoritative Dart repositories: a credential AND at least
  /// one protected app.
  final bool? protectionConfigured;

  /// An app credential (PIN/pattern) is enrolled.
  final bool? credentialConfigured;

  /// At least one app is protected.
  final bool? hasProtectedApps;

  /// Native enforcement is enabled (`ProtectionStateStore.isEnabled`, via
  /// `getHealth.protectionConfigured`). Saved Dart configuration alone is
  /// not evidence that native code enforces it.
  final bool? nativeProtectionEnabled;

  final bool? overlayGranted;
  final bool overlayEverGranted;

  /// Listed in Android's enabled Accessibility services.
  final bool? accessibilityEnabled;
  final bool accessibilityEverGranted;

  /// Android currently has the service bound (native, process-local).
  final bool? accessibilityConnected;

  final bool? usageAccessGranted;
  final bool usageAccessEverGranted;

  /// The native `getHealth` read succeeded (watcher/shield/power signals
  /// below are only meaningful when it did).
  final bool nativeHealthAvailable;
  final bool? watcherRunning;
  final String? watcherLastError;
  final bool? shieldArmed;
  final bool? notificationsGranted;
  final bool? backgroundRestricted;
  final int? sdkInt;
  final bool? powerSaveMode;
  final bool? ignoringBatteryOptimizations;

  /// The user enabled biometric unlock in Smart App Lock.
  final bool? biometricUnlockEnabled;
  final bool? biometricHardwarePresent;
  final bool? biometricEnrolled;

  Map<String, Object?> toJson() => <String, Object?>{
        'observedAt': observedAt.toIso8601String(),
        'protectionConfigured': protectionConfigured,
        'credentialConfigured': credentialConfigured,
        'hasProtectedApps': hasProtectedApps,
        'nativeProtectionEnabled': nativeProtectionEnabled,
        'overlayGranted': overlayGranted,
        'overlayEverGranted': overlayEverGranted,
        'accessibilityEnabled': accessibilityEnabled,
        'accessibilityEverGranted': accessibilityEverGranted,
        'accessibilityConnected': accessibilityConnected,
        'usageAccessGranted': usageAccessGranted,
        'usageAccessEverGranted': usageAccessEverGranted,
        'nativeHealthAvailable': nativeHealthAvailable,
        'watcherRunning': watcherRunning,
        'shieldArmed': shieldArmed,
        'notificationsGranted': notificationsGranted,
        'backgroundRestricted': backgroundRestricted,
        'sdkInt': sdkInt,
        'powerSaveMode': powerSaveMode,
        'ignoringBatteryOptimizations': ignoringBatteryOptimizations,
        'biometricUnlockEnabled': biometricUnlockEnabled,
        'biometricHardwarePresent': biometricHardwarePresent,
        'biometricEnrolled': biometricEnrolled,
      };
}

/// Known platform limitations attached to every report.
abstract final class HealthLimitation {
  /// OEM power managers (for example ColorOS) have no public API; their
  /// state is always UNKNOWN and is never claimed as unrestricted.
  static const String oemBackgroundControlsUnobservable =
      'oem_background_controls_unobservable';

  /// `ActivityManager.isBackgroundRestricted` needs API 28+.
  static const String backgroundRestrictionApiUnsupported =
      'background_restriction_api_unsupported';
}

/// The evaluated health.
class ProtectionHealthReport {
  const ProtectionHealthReport._({
    required this.state,
    required this.issues,
    required this.components,
    required this.signals,
    required this.evaluatedAt,
    required this.stale,
    required this.limitations,
  });

  final ProtectionHealthState state;

  /// Deterministically ordered: severity, then code, then component.
  final List<HealthIssue> issues;
  final Map<HealthComponent, ComponentStatus> components;
  final HealthSignals signals;
  final DateTime evaluatedAt;
  final bool stale;
  final List<String> limitations;

  DateTime get observedAt => signals.observedAt;

  bool hasIssue(HealthIssueCode code) =>
      issues.any((HealthIssue issue) => issue.code == code);

  /// Stable fingerprint of what a UI would show (state, issues, statuses);
  /// used to emit change events only when something meaningful changed.
  String get signature => <String>[
        state.id,
        for (final HealthIssue issue in issues)
          '${issue.code.id}/${issue.component.id}/${issue.cause.id}',
        for (final MapEntry<HealthComponent, ComponentStatus> entry
            in components.entries)
          '${entry.key.id}=${entry.value.id}',
      ].join('|');

  Map<String, Object?> toJson() => <String, Object?>{
        'state': state.id,
        'stale': stale,
        'observedAt': observedAt.toIso8601String(),
        'evaluatedAt': evaluatedAt.toIso8601String(),
        'issues': <Map<String, Object?>>[
          for (final HealthIssue issue in issues) issue.toJson(),
        ],
        'components': <String, String>{
          for (final MapEntry<HealthComponent, ComponentStatus> entry
              in components.entries)
            entry.key.id: entry.value.id,
        },
        'limitations': List<String>.of(limitations),
      };
}

/// The pure classifier.
abstract final class ProtectionHealthEngine {
  /// A snapshot older than this can no longer support SECURE.
  static const Duration defaultMaxAge = Duration(seconds: 30);

  static ProtectionHealthReport evaluate(
    HealthSignals s, {
    required DateTime now,
    Duration maxAge = defaultMaxAge,
  }) {
    final Map<HealthComponent, ComponentStatus> components = _components(s);
    final List<HealthIssue> issues = <HealthIssue>[];

    final Duration age = now.difference(s.observedAt);
    // A future-dated snapshot (wall clock moved back) cannot be trusted.
    final bool stale = age.isNegative || age > maxAge;

    if (s.protectionConfigured == false) {
      final bool setup = s.credentialConfigured == false;
      issues.add(
        HealthIssue(
          code: HealthIssueCode.protectionNotConfigured,
          component: HealthComponent.protectionConfiguration,
          cause: setup
              ? HealthCause.setupIncomplete
              : s.hasProtectedApps == false
                  ? HealthCause.noProtectedApps
                  : HealthCause.userChoice,
          action: setup
              ? HealthRepairAction.configureProtection
              : HealthRepairAction.chooseProtectedApps,
        ),
      );
    } else {
      if (s.protectionConfigured == null) {
        issues.add(_unknown(HealthComponent.protectionConfiguration));
      }
      _coreIssues(s, components, issues);
      _advisories(s, components, issues);
    }
    if (stale) {
      issues.add(
        HealthIssue(
          code: HealthIssueCode.healthSnapshotStale,
          component: HealthComponent.nativeHealth,
          cause: HealthCause.stale,
          action: HealthRepairAction.refresh,
          detail: <String, String>{'ageMs': '${age.inMilliseconds}'},
        ),
      );
    }
    issues.sort(_compare);

    final ProtectionHealthState state;
    if (issues
        .any((HealthIssue i) => i.severity == HealthIssueSeverity.offline)) {
      state = ProtectionHealthState.protectionOffline;
    } else if (issues
        .any((HealthIssue i) => i.severity == HealthIssueSeverity.attention)) {
      state = ProtectionHealthState.attentionRequired;
    } else {
      state = ProtectionHealthState.secure;
    }

    return ProtectionHealthReport._(
      state: state,
      issues: List<HealthIssue>.unmodifiable(issues),
      components:
          Map<HealthComponent, ComponentStatus>.unmodifiable(components),
      signals: s,
      evaluatedAt: now,
      stale: stale,
      limitations: List<String>.unmodifiable(<String>[
        HealthLimitation.oemBackgroundControlsUnobservable,
        if (components[HealthComponent.backgroundRestriction] ==
            ComponentStatus.unsupported)
          HealthLimitation.backgroundRestrictionApiUnsupported,
      ]),
    );
  }

  /// Re-applies the age rule to an earlier observation (no new probes).
  static ProtectionHealthReport reevaluate(
    ProtectionHealthReport report, {
    required DateTime now,
    Duration maxAge = defaultMaxAge,
  }) =>
      evaluate(report.signals, now: now, maxAge: maxAge);

  // -- detection paths ------------------------------------------------------

  /// Accessibility detection is operational only when it is enabled in
  /// Settings AND Android has the service bound.
  static bool? accessibilityPath(HealthSignals s) {
    if (s.accessibilityEnabled == false) return false;
    if (s.accessibilityEnabled == null) return null;
    // The bound signal comes from native health; without it, UNKNOWN.
    return s.nativeHealthAvailable ? s.accessibilityConnected : null;
  }

  /// UsageEvents recovery polling runs inside the native watcher; it needs
  /// both Usage Access and a running watcher.
  static bool? usageAccessPath(HealthSignals s) {
    final bool? watcher = s.nativeHealthAvailable ? s.watcherRunning : null;
    if (s.usageAccessGranted == false || watcher == false) return false;
    if (s.usageAccessGranted == null || watcher == null) return null;
    return true;
  }

  // -- components -----------------------------------------------------------

  static Map<HealthComponent, ComponentStatus> _components(HealthSignals s) {
    final bool native = s.nativeHealthAvailable;
    return <HealthComponent, ComponentStatus>{
      HealthComponent.protectionConfiguration: switch (s.protectionConfigured) {
        true => ComponentStatus.operational,
        false => s.credentialConfigured == false
            ? ComponentStatus.notSetUp
            : ComponentStatus.disabledByUser,
        null => ComponentStatus.unknown,
      },
      HealthComponent.nativeEnforcement:
          _running(native ? s.nativeProtectionEnabled : null),
      HealthComponent.overlay: _grant(s.overlayGranted, s.overlayEverGranted),
      HealthComponent.accessibilityDetection: switch (s.accessibilityEnabled) {
        false => _grant(false, s.accessibilityEverGranted),
        null => ComponentStatus.unknown,
        true => switch (native ? s.accessibilityConnected : null) {
            true => ComponentStatus.operational,
            false => ComponentStatus.notRunning,
            null => ComponentStatus.unknown,
          },
      },
      HealthComponent.usageAccessDetection:
          _grant(s.usageAccessGranted, s.usageAccessEverGranted),
      HealthComponent.watcher: _running(native ? s.watcherRunning : null),
      HealthComponent.shield: _running(native ? s.shieldArmed : null),
      HealthComponent.notifications: switch (
          native ? s.notificationsGranted : null) {
        true => ComponentStatus.operational,
        false => ComponentStatus.notSetUp,
        null => ComponentStatus.unknown,
      },
      HealthComponent.backgroundRestriction: _backgroundRestriction(s),
      HealthComponent.oemBackgroundControls: ComponentStatus.unknown,
      HealthComponent.batterySaver: switch (native ? s.powerSaveMode : null) {
        true => ComponentStatus.restricted,
        false => ComponentStatus.operational,
        null => ComponentStatus.unknown,
      },
      HealthComponent.biometric: _biometric(s),
      HealthComponent.nativeHealth:
          native ? ComponentStatus.operational : ComponentStatus.unknown,
    };
  }

  static ComponentStatus _grant(bool? granted, bool everGranted) =>
      switch (granted) {
        true => ComponentStatus.operational,
        false =>
          everGranted ? ComponentStatus.revoked : ComponentStatus.notSetUp,
        null => ComponentStatus.unknown,
      };

  static ComponentStatus _running(bool? running) => switch (running) {
        true => ComponentStatus.operational,
        false => ComponentStatus.notRunning,
        null => ComponentStatus.unknown,
      };

  static ComponentStatus _backgroundRestriction(HealthSignals s) {
    final int? sdk = s.nativeHealthAvailable ? s.sdkInt : null;
    if (sdk != null && sdk < 28) return ComponentStatus.unsupported;
    return switch (s.nativeHealthAvailable ? s.backgroundRestricted : null) {
      true => ComponentStatus.restricted,
      false => ComponentStatus.operational,
      null => ComponentStatus.unknown,
    };
  }

  static ComponentStatus _biometric(HealthSignals s) {
    if (s.biometricUnlockEnabled == false) {
      return ComponentStatus.disabledByUser;
    }
    if (s.biometricUnlockEnabled == null) return ComponentStatus.unknown;
    if (s.biometricHardwarePresent == false) return ComponentStatus.unsupported;
    return switch (s.biometricEnrolled) {
      true => ComponentStatus.operational,
      false => ComponentStatus.notSetUp,
      null => ComponentStatus.unknown,
    };
  }

  // -- issues ---------------------------------------------------------------

  static void _coreIssues(
    HealthSignals s,
    Map<HealthComponent, ComponentStatus> c,
    List<HealthIssue> issues,
  ) {
    final bool native = s.nativeHealthAvailable;
    if (!native) {
      // One issue for the whole native snapshot instead of one per signal.
      issues.add(_unknown(HealthComponent.nativeHealth));
    }

    // Native enforcement must actually be enabled for saved configuration
    // to mean anything (shield, recovery and watcher consult it).
    if (native && s.protectionConfigured == true) {
      switch (s.nativeProtectionEnabled) {
        case false:
          issues.add(
            const HealthIssue(
              code: HealthIssueCode.enforcementNotArmed,
              component: HealthComponent.nativeEnforcement,
              cause: HealthCause.notRunning,
              action: HealthRepairAction.openSmartAppLock,
            ),
          );
        case null:
          issues.add(_unknown(HealthComponent.nativeEnforcement));
        case true:
          break;
      }
    }

    // Required overlay (shield + challenge presentation).
    switch (s.overlayGranted) {
      case false:
        issues.add(
          HealthIssue(
            code: HealthIssueCode.overlayUnavailable,
            component: HealthComponent.overlay,
            cause: _grantCause(c[HealthComponent.overlay]!),
            action: HealthRepairAction.openOverlaySettings,
          ),
        );
      case null:
        issues.add(_unknown(HealthComponent.overlay));
      case true:
        if (native && s.shieldArmed == false) {
          issues.add(
            const HealthIssue(
              code: HealthIssueCode.shieldNotArmed,
              component: HealthComponent.shield,
              cause: HealthCause.notRunning,
              action: HealthRepairAction.openSmartAppLock,
            ),
          );
        } else if (native && s.shieldArmed == null) {
          issues.add(_unknown(HealthComponent.shield));
        }
    }

    // Foreground detection paths.
    final bool? a11y = accessibilityPath(s);
    final bool? usage = usageAccessPath(s);
    if (a11y == false && usage == false) {
      issues.add(
        HealthIssue(
          code: HealthIssueCode.detectionOffline,
          component: HealthComponent.accessibilityDetection,
          cause: _detectionCause(c),
          action: HealthRepairAction.openAccessibilitySettings,
          detail: <String, String>{
            'accessibility': c[HealthComponent.accessibilityDetection]!.id,
            'usageAccess': c[HealthComponent.usageAccessDetection]!.id,
            'watcher': c[HealthComponent.watcher]!.id,
          },
        ),
      );
    }
    switch (c[HealthComponent.accessibilityDetection]!) {
      case ComponentStatus.notSetUp:
      case ComponentStatus.revoked:
        issues.add(
          HealthIssue(
            code: HealthIssueCode.accessibilityUnavailable,
            component: HealthComponent.accessibilityDetection,
            cause: _grantCause(c[HealthComponent.accessibilityDetection]!),
            action: HealthRepairAction.openAccessibilitySettings,
          ),
        );
      case ComponentStatus.notRunning:
        issues.add(
          const HealthIssue(
            code: HealthIssueCode.accessibilityNotRunning,
            component: HealthComponent.accessibilityDetection,
            cause: HealthCause.notRunning,
            action: HealthRepairAction.openAccessibilitySettings,
          ),
        );
      case ComponentStatus.unknown:
        // A missing native snapshot is already one issue; only a failed
        // Settings read adds its own.
        if (native || s.accessibilityEnabled == null) {
          issues.add(_unknown(HealthComponent.accessibilityDetection));
        }
      default:
        break;
    }
    switch (c[HealthComponent.usageAccessDetection]!) {
      case ComponentStatus.notSetUp:
      case ComponentStatus.revoked:
        issues.add(
          HealthIssue(
            code: HealthIssueCode.usageAccessUnavailable,
            component: HealthComponent.usageAccessDetection,
            cause: _grantCause(c[HealthComponent.usageAccessDetection]!),
            action: HealthRepairAction.openUsageAccessSettings,
          ),
        );
      case ComponentStatus.unknown:
        issues.add(_unknown(HealthComponent.usageAccessDetection));
      default:
        break;
    }

    if (!native) return;

    // Native watcher (screen-off re-lock, wake tickets, usage polling).
    switch (s.watcherRunning) {
      case false:
        final String? error = s.watcherLastError;
        issues.add(
          HealthIssue(
            code: HealthIssueCode.watcherNotRunning,
            component: HealthComponent.watcher,
            cause: HealthCause.notRunning,
            action: HealthRepairAction.openSmartAppLock,
            detail: <String, String>{
              if (error != null && error.isNotEmpty) 'lastError': error,
            },
          ),
        );
      case null:
        issues.add(_unknown(HealthComponent.watcher));
      case true:
        break;
    }

    switch (s.notificationsGranted) {
      case false:
        issues.add(
          const HealthIssue(
            code: HealthIssueCode.notificationsDisabled,
            component: HealthComponent.notifications,
            cause: HealthCause.notGranted,
            action: HealthRepairAction.openNotificationSettings,
          ),
        );
      case null:
        issues.add(_unknown(HealthComponent.notifications));
      case true:
        break;
    }

    switch (c[HealthComponent.backgroundRestriction]!) {
      case ComponentStatus.restricted:
        issues.add(
          HealthIssue(
            code: HealthIssueCode.backgroundRestricted,
            component: HealthComponent.backgroundRestriction,
            cause: HealthCause.restricted,
            action: HealthRepairAction.openAppBatterySettings,
            detail: <String, String>{
              if (s.sdkInt != null) 'sdkInt': '${s.sdkInt}',
            },
          ),
        );
      case ComponentStatus.unknown:
        issues.add(_unknown(HealthComponent.backgroundRestriction));
      default:
        break; // operational, or unsupported below API 28 (a limitation)
    }
  }

  static void _advisories(
    HealthSignals s,
    Map<HealthComponent, ComponentStatus> c,
    List<HealthIssue> issues,
  ) {
    if (c[HealthComponent.batterySaver] == ComponentStatus.restricted) {
      issues.add(
        const HealthIssue(
          code: HealthIssueCode.batterySaverOn,
          component: HealthComponent.batterySaver,
          cause: HealthCause.restricted,
          action: HealthRepairAction.openBatterySaverSettings,
        ),
      );
    }
    // Biometric is an optional accelerator: a missing enrollment or sensor
    // is advisory only and never affects the protection state.
    final ComponentStatus biometric = c[HealthComponent.biometric]!;
    if (biometric == ComponentStatus.notSetUp ||
        biometric == ComponentStatus.unsupported) {
      issues.add(
        HealthIssue(
          code: HealthIssueCode.biometricUnavailable,
          component: HealthComponent.biometric,
          cause: biometric == ComponentStatus.unsupported
              ? HealthCause.unsupported
              : HealthCause.notEnrolled,
          action: biometric == ComponentStatus.unsupported
              ? null
              : HealthRepairAction.openBiometricSettings,
        ),
      );
    }
  }

  /// Why both detection paths are down. Revocation wins, then a stopped
  /// component; only when every reason is "never granted" is it setup.
  static HealthCause _detectionCause(Map<HealthComponent, ComponentStatus> c) {
    final ComponentStatus a11y = c[HealthComponent.accessibilityDetection]!;
    final ComponentStatus usage = c[HealthComponent.usageAccessDetection]!;
    // The usage path's reason is its grant, or else the stopped watcher.
    final ComponentStatus usageReason = usage == ComponentStatus.operational
        ? c[HealthComponent.watcher]!
        : usage;
    final List<ComponentStatus> reasons = <ComponentStatus>[a11y, usageReason];
    if (reasons.contains(ComponentStatus.revoked)) return HealthCause.revoked;
    if (reasons.every((ComponentStatus r) => r == ComponentStatus.notSetUp)) {
      return HealthCause.notGranted;
    }
    return HealthCause.notRunning;
  }

  static HealthCause _grantCause(ComponentStatus status) =>
      status == ComponentStatus.revoked
          ? HealthCause.revoked
          : HealthCause.notGranted;

  static HealthIssue _unknown(HealthComponent component) => HealthIssue(
        code: HealthIssueCode.signalUnknown,
        component: component,
        cause: HealthCause.unknown,
        action: HealthRepairAction.refresh,
      );

  static int _compare(HealthIssue a, HealthIssue b) {
    final int severity = a.severity.index.compareTo(b.severity.index);
    if (severity != 0) return severity;
    final int code = a.code.index.compareTo(b.code.index);
    if (code != 0) return code;
    return a.component.index.compareTo(b.component.index);
  }
}
