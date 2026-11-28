import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../design_system/design_system.dart';
import '../../../services/watcher_service.dart';
import '../../../utilities/result.dart';

/// What Android reported for one capability.
enum OnboardingPermissionStatus {
  /// Android confirmed the capability is granted/enabled.
  enabled,

  /// Android confirmed it is not granted.
  notEnabled,

  /// The state could not be read. Never shown as granted.
  unknown,
}

/// One capability explained during onboarding (Phase 15 / M2).
class OnboardingPermission {
  const OnboardingPermission({
    required this.id,
    required this.title,
    required this.why,
    required this.route,
    required this.icon,
    required this.required,
  });

  final String id;
  final String title;

  /// Plain-language reason Smart App Lock needs it.
  final String why;

  /// The EXISTING dedicated setup flow (disclosure → Android settings →
  /// re-check). Core rows never open system settings directly.
  final String route;
  final IconData icon;

  /// Required for the native lock; otherwise recommended.
  final bool required;
}

/// Reads a capability from Android. Overridable in tests.
typedef OnboardingPermissionProbe = Future<Result<bool>> Function();

/// Maps an Android read to a status. Only a successful `true` is
/// [OnboardingPermissionStatus.enabled]; a failure (or an exception) is
/// [OnboardingPermissionStatus.unknown], never "enabled".
Future<OnboardingPermissionStatus> readOnboardingPermission(
  OnboardingPermissionProbe probe,
) async {
  try {
    final Result<bool> result = await probe();
    if (result.isFailure) {
      return OnboardingPermissionStatus.unknown;
    }
    return result.valueOrNull == true
        ? OnboardingPermissionStatus.enabled
        : OnboardingPermissionStatus.notEnabled;
  } catch (_) {
    return OnboardingPermissionStatus.unknown;
  }
}

/// First Android release with the runtime notification permission
/// (POST_NOTIFICATIONS, Android 13 / API 33).
const int onboardingNotificationMinSdk = 33;

/// The Android 13+ notification permission as read from Android.
class OnboardingNotificationReading {
  const OnboardingNotificationReading({
    required this.applicable,
    required this.status,
    this.sdkInt,
  });

  /// False only when Android reported an SDK below 13 (no runtime
  /// permission there). Unknown SDK → shown.
  final bool applicable;
  final OnboardingPermissionStatus status;

  /// Android SDK level as reported by Android; null when unknown.
  final int? sdkInt;
}

/// Maps the native health read to the notification row (Phase 15 final).
/// Only a successful read reporting the permission granted is
/// [OnboardingPermissionStatus.enabled]; a failure or exception is
/// [OnboardingPermissionStatus.unknown] and the row stays visible.
Future<OnboardingNotificationReading> readOnboardingNotifications(
  Future<Result<ProtectionEngineHealth>> Function() probe,
) async {
  const OnboardingNotificationReading unknown = OnboardingNotificationReading(
    applicable: true,
    status: OnboardingPermissionStatus.unknown,
  );
  try {
    final Result<ProtectionEngineHealth> result = await probe();
    final ProtectionEngineHealth? health = result.valueOrNull;
    if (result.isFailure || health == null) {
      return unknown;
    }
    final int? sdk = health.sdkInt;
    return OnboardingNotificationReading(
      sdkInt: sdk,
      applicable: sdk == null || sdk >= onboardingNotificationMinSdk,
      status: health.notificationPermissionGranted
          ? OnboardingPermissionStatus.enabled
          : OnboardingPermissionStatus.notEnabled,
    );
  } catch (_) {
    return unknown;
  }
}

/// Phase 15 / M2 — permission education and guided activation.
///
/// Explains each capability and opens the app's existing setup flow for it
/// (Accessibility and Draw over apps keep their prominent disclosure and
/// the Android settings hand-off unchanged). Status is re-read from Android
/// after every return and on app resume; nothing is granted here. The user
/// may continue without granting: protection then stays incomplete and the
/// step says so.
///
/// Guided setup: the step is the single central setup hub. It shows
/// progress, the items Android already reports as allowed, and ONE current
/// item (order: Accessibility, Draw over apps, Usage access) with one main
/// action. The action opens that item's existing flow (Accessibility keeps
/// its prominent disclosure and Agree / Not now consent before the Android
/// hand-off); after the user comes back from Android settings the flow
/// returns here, status is re-read and the next missing item is shown.
/// Nothing is opened without a new tap. Short troubleshooting appears only
/// after the user has come back from Android settings at least twice for
/// the same item without Android reporting it enabled; Restricted Settings
/// guidance is offered there behind "Help" (never auto-detected).
///
/// Phase 15 final: on Android 13+ an optional, separately explained
/// Notifications row opens this app's Android notification settings through
/// the existing `openProtectionSettings` hand-off (as Protection Health
/// does). It never counts toward the required set and never blocks
/// continuing.
class OnboardingPermissionsStep extends StatefulWidget {
  const OnboardingPermissionsStep({
    super.key,
    required this.onContinue,
    this.probes,
  });

  final VoidCallback onContinue;

  /// Test seam: capability id → probe. Defaults to the app's services.
  final Map<String, OnboardingPermissionProbe>? probes;

  static const String title = 'Set Up Protection';
  static const String subtitle =
      'Android asks you to allow each item yourself. Follow one step at a '
      'time; this screen updates when you come back.';
  static const String enabledLabel = 'Enabled';
  static const String notEnabledRequiredLabel = 'Required';
  static const String notEnabledRecommendedLabel = 'Recommended';
  static const String unknownLabel = "Couldn't check";
  static const String continueLabel = 'Continue';
  static const String skipLabel = 'Skip for now';
  static const String incompleteNote =
      'Protected apps will not lock until Accessibility and the lock shield '
      'are both enabled. You can finish this later in Security → App '
      'lock permissions.';
  static const String openFailedMessage =
      "Couldn't open that setup screen. Please try again.";

  // -- Guided setup -------------------------------------------------------
  /// Progress counts only the REQUIRED items (Accessibility, Draw over
  /// apps); Usage access is a recommended extra and never counted as
  /// mandatory. Display only: protection status comes from health checks.
  static String progressLabel(int done, int total) =>
      '$done of $total required allowed';
  static String stepLabel(int step, int total) => 'Step $step of $total';
  static const String extraStepLabel = 'Extra step';
  static const String allowLabel = 'Allow';
  static const String tryAgainLabel = 'Try Again';
  static const String helpLabel = 'Help';
  static const String hideHelpLabel = 'Hide help';
  static const String checkAgainLabel = 'Check again';
  static const String recommendedTag = 'Recommended';
  static const String checklistHeading = 'Your setup';
  static const String unknownNote =
      "Couldn't confirm this with Android. If you already allowed it, tap "
      'Check again.';
  static const String allSetTitle = 'All three are allowed';
  static const String allSetMessage =
      'Android reports every item above as allowed. Next, choose your apps; '
      'Smart App Lock then checks that protection is working.';

  /// What the user does for each item (shown on the current step).
  static const Map<String, String> howTo = <String, String>{
    'accessibility': 'Tap Allow and read why it is needed. If you agree, '
        'Android opens its Accessibility settings: find Smart App Lock, '
        'turn it on, then come back.',
    'overlay': 'Tap Allow, then Open Settings. Turn on Smart App Lock in '
        '"Display over other apps", then come back.',
    'usage': 'Recommended, not required. Tap Allow, then Open Settings. '
        'Turn on usage access for Smart App Lock, then come back.',
  };

  // -- Troubleshooting (only after repeated returns without a grant) ------
  static const String notEnabledTitle = 'Permission not enabled';
  static const String notEnabledMessage =
      "Android hasn't enabled this permission yet.";

  /// General help per item.
  static const Map<String, String> helpGeneral = <String, String>{
    'accessibility': 'Make sure you turned on Smart App Lock itself. In '
        'Accessibility settings it may be listed in a section such as '
        'downloaded or installed apps.',
    'overlay': 'Find Smart App Lock in the "Display over other apps" list '
        'and turn on its switch.',
    'usage': 'Find Smart App Lock in the "Usage access" list and turn on '
        'its switch.',
  };
  static const String restrictedHeading =
      'If Android says "Controlled by restricted setting" or "App was '
      'denied access"';
  static const String restrictedSteps =
      '1. Open Smart App Lock\'s App info.\n'
      '2. Tap the \u22EE menu and choose "Allow restricted settings", if you '
      'see it.\n'
      '3. Come back here and tap Try Again.';
  static const String restrictedTrust =
      'Only do this if you trust this app. This option is not on every '
      'phone and depends on Android and your phone maker.';
  static const String restrictedAlternative =
      'If the option is not there: Try installing Smart App Lock from its '
      "official Google Play listing when available, or check your phone "
      "manufacturer's permission guidance.";
  static const String openAppInfoLabel = 'Open App info';
  static const String appInfoOpenFailedMessage =
      "Couldn't open App info. Open your phone's Settings app, then Apps, "
      'then Smart App Lock.';

  /// Restricted Settings exist from Android 13 (API 33).
  static const int restrictedSettingsMinSdk = 33;

  static const String optionalHeading = 'Optional — not needed for app locking';
  static const String notificationsTitle = 'Notifications';
  static const String notificationsWhy =
      'Lets Smart App Lock show its protection status notification (and '
      'notification privacy placeholders, if you use them). App locking '
      'does not depend on it: protected apps still lock without it, but you '
      'may not notice if protection stops. Opens Android notification '
      'settings.';
  static const String notificationsOptionalLabel = 'Optional';

  static const List<OnboardingPermission> permissions = <OnboardingPermission>[
    OnboardingPermission(
      id: 'accessibility',
      title: 'Accessibility service',
      why: 'Tells Smart App Lock which app just opened, so a protected app '
          'is covered right away. It never reads your screen, types or '
          'taps for you, or collects data.',
      route: RouteNames.accessibilitySetup,
      icon: Icons.accessibility_new,
      required: true,
    ),
    OnboardingPermission(
      id: 'overlay',
      title: 'Draw over apps',
      why: 'Shows the lock shield over a protected app while the PIN, '
          'pattern or biometric screen opens. Used only for the lock '
          'screen.',
      route: RouteNames.overlaySetup,
      icon: Icons.layers,
      required: true,
    ),
    OnboardingPermission(
      id: 'usage',
      title: 'Usage access',
      why: 'A slower backup that notices protected apps if the '
          'Accessibility service is stopped. Optional but recommended.',
      route: RouteNames.usageAccess,
      icon: Icons.insights,
      required: false,
    ),
  ];

  @override
  State<OnboardingPermissionsStep> createState() =>
      _OnboardingPermissionsStepState();
}

class _OnboardingPermissionsStepState extends State<OnboardingPermissionsStep>
    with WidgetsBindingObserver {
  final Map<String, OnboardingPermissionStatus> _status =
      <String, OnboardingPermissionStatus>{};
  OnboardingNotificationReading _notifications =
      const OnboardingNotificationReading(
    applicable: true,
    status: OnboardingPermissionStatus.unknown,
  );
  bool _checking = true;
  bool _opening = false;
  String? _message;

  /// Guided setup: per item, how often the user came back from Android
  /// settings (via that item's flow) with Android still reporting it not
  /// enabled. An explicit decline (Not now) or Back without leaving the app
  /// is not counted. Session memory only.
  final Map<String, int> _notEnabledReturns = <String, int>{};
  bool _flowOpen = false;
  bool _leftAppDuringFlow = false;
  String? _helpOpenFor;
  String? _helpMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Returning from Android settings directly also re-checks.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // The open flow handed off to Android settings.
      if (_flowOpen) _leftAppDuringFlow = true;
    }
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Map<String, OnboardingPermissionProbe> _probes() {
    final Map<String, OnboardingPermissionProbe>? override = widget.probes;
    if (override != null) {
      return override;
    }
    final container = AppScope.read(context);
    if (container == null) {
      return const <String, OnboardingPermissionProbe>{};
    }
    return <String, OnboardingPermissionProbe>{
      'accessibility': container.accessibility.isServiceEnabled,
      'overlay': container.overlay.canDrawOverlays,
      'usage': container.installedAppsService.hasUsageAccess,
    };
  }

  Future<void> _refresh() async {
    if (!mounted) {
      return;
    }
    final Map<String, OnboardingPermissionProbe> probes = _probes();
    final Map<String, OnboardingPermissionStatus> next =
        <String, OnboardingPermissionStatus>{};
    for (final OnboardingPermission p
        in OnboardingPermissionsStep.permissions) {
      final OnboardingPermissionProbe? probe = probes[p.id];
      next[p.id] = probe == null
          ? OnboardingPermissionStatus.unknown
          : await readOnboardingPermission(probe);
    }
    final OnboardingNotificationReading notifications =
        await _readNotifications();
    if (!mounted) {
      return;
    }
    setState(() {
      _status
        ..clear()
        ..addAll(next);
      _notifications = notifications;
      _checking = false;
    });
  }

  Future<OnboardingNotificationReading> _readNotifications() {
    final container = widget.probes == null ? AppScope.read(context) : null;
    if (container == null) {
      // No Android read available (or a probe override without one):
      // unknown, never granted.
      return Future<OnboardingNotificationReading>.value(
        const OnboardingNotificationReading(
          applicable: true,
          status: OnboardingPermissionStatus.unknown,
        ),
      );
    }
    return readOnboardingNotifications(container.watcher.getHealth);
  }

  Future<void> _openNotifications() async {
    if (_opening) {
      return;
    }
    final container = AppScope.read(context);
    setState(() {
      _opening = true;
      _message = null;
    });
    bool opened = false;
    try {
      // Android decides; the result is not trusted — re-read below.
      final Result<bool>? result = await container?.watcher
          .openProtectionSettings(ProtectionSettingsTarget.notifications);
      opened = result != null && result.isSuccess && result.valueOrNull == true;
    } catch (_) {
      opened = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _opening = false;
      if (!opened) _message = OnboardingPermissionsStep.openFailedMessage;
    });
    await _refresh();
  }

  OnboardingPermissionStatus _of(String id) =>
      _status[id] ?? OnboardingPermissionStatus.unknown;

  bool get _coreReady => OnboardingPermissionsStep.permissions
      .where((OnboardingPermission p) => p.required)
      .every(
        (OnboardingPermission p) =>
            _of(p.id) == OnboardingPermissionStatus.enabled,
      );

  Future<void> _open(OnboardingPermission permission) async {
    if (_opening) {
      return;
    }
    setState(() {
      _opening = true;
      _message = null;
      _helpMessage = null;
    });
    _flowOpen = true;
    _leftAppDuringFlow = false;
    bool opened = true;
    try {
      // The existing flow handles disclosure, denial, cancellation and an
      // unavailable settings screen; it returns here after the Android
      // hand-off. Its pop result is not trusted — re-read below.
      await Navigator.of(context).pushNamed<Object?>(
        permission.route,
        arguments: RouteNames.returnToSetupArgument,
      );
    } catch (_) {
      opened = false;
      if (mounted) {
        setState(() => _message = OnboardingPermissionsStep.openFailedMessage);
      }
    } finally {
      _flowOpen = false;
      if (mounted) {
        setState(() => _opening = false);
      }
    }
    await _refresh();
    if (!mounted) {
      return;
    }
    if (opened &&
        _leftAppDuringFlow &&
        _of(permission.id) == OnboardingPermissionStatus.notEnabled) {
      setState(() {
        _notEnabledReturns[permission.id] =
            (_notEnabledReturns[permission.id] ?? 0) + 1;
      });
    }
  }

  /// Help → App info (allowlisted target; opening it grants nothing).
  Future<void> _openAppInfo() async {
    if (_opening) {
      return;
    }
    final container = AppScope.read(context);
    setState(() {
      _opening = true;
      _helpMessage = null;
    });
    bool opened = false;
    try {
      final Result<bool>? result = await container?.watcher
          .openProtectionSettings(ProtectionSettingsTarget.appDetails);
      opened = result != null && result.isSuccess && result.valueOrNull == true;
    } catch (_) {
      opened = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _opening = false;
      if (!opened) {
        _helpMessage = OnboardingPermissionsStep.appInfoOpenFailedMessage;
      }
    });
  }

  /// The first item Android does not report as enabled, in setup order.
  OnboardingPermission? get _current {
    for (final OnboardingPermission p
        in OnboardingPermissionsStep.permissions) {
      if (_of(p.id) != OnboardingPermissionStatus.enabled) {
        return p;
      }
    }
    return null;
  }

  List<OnboardingPermission> get _required => OnboardingPermissionsStep
      .permissions
      .where((OnboardingPermission p) => p.required)
      .toList();

  int get _requiredAllowedCount => _required
      .where(
        (OnboardingPermission p) =>
            _of(p.id) == OnboardingPermissionStatus.enabled,
      )
      .length;

  bool get _restrictedHelpApplies {
    final int? sdk = _notifications.sdkInt;
    return sdk == null ||
        sdk >= OnboardingPermissionsStep.restrictedSettingsMinSdk;
  }

  String _label(OnboardingPermission p) => switch (_of(p.id)) {
        OnboardingPermissionStatus.enabled =>
          OnboardingPermissionsStep.enabledLabel,
        OnboardingPermissionStatus.notEnabled => p.required
            ? OnboardingPermissionsStep.notEnabledRequiredLabel
            : OnboardingPermissionsStep.notEnabledRecommendedLabel,
        OnboardingPermissionStatus.unknown =>
          OnboardingPermissionsStep.unknownLabel,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final String? message = _message;
    return ListView(
      key: const ValueKey<String>('onboarding_permissions'),
      padding: DsInsets.screen,
      children: <Widget>[
        Text(OnboardingPermissionsStep.title,
            style: theme.textTheme.headlineSmall),
        const SizedBox(height: DsSpacing.sm),
        Text(
          OnboardingPermissionsStep.subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette.textSecondary,
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        _buildProgress(theme, palette),
        const SizedBox(height: DsSpacing.lg),
        if (!_checking) ...<Widget>[
          _buildCurrent(theme, palette),
          const SizedBox(height: DsSpacing.xl),
        ],
        Text(
          OnboardingPermissionsStep.checklistHeading,
          style: theme.textTheme.labelLarge?.copyWith(
            color: palette.textSecondary,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        for (final OnboardingPermission p
            in OnboardingPermissionsStep.permissions) ...<Widget>[
          DsCard(
            key: Key('onboarding_perm_${p.id}'),
            onTap: _checking || _opening ? null : () => _open(p),
            child: Row(
              children: <Widget>[
                Icon(
                  _of(p.id) == OnboardingPermissionStatus.enabled
                      ? Icons.check_circle
                      : p.icon,
                  color: _of(p.id) == OnboardingPermissionStatus.enabled
                      ? palette.success
                      : palette.primary,
                ),
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: Text(p.title, style: theme.textTheme.titleSmall),
                ),
                const SizedBox(width: DsSpacing.sm),
                if (_checking)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  DsStatusPill(
                    key: Key('onboarding_perm_${p.id}_status'),
                    label: _label(p),
                    tone: switch (_of(p.id)) {
                      OnboardingPermissionStatus.enabled => DsTone.success,
                      OnboardingPermissionStatus.notEnabled =>
                        p.required ? DsTone.danger : DsTone.warning,
                      OnboardingPermissionStatus.unknown => DsTone.warning,
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
        ],
        if (_notifications.applicable) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Text(
            OnboardingPermissionsStep.optionalHeading,
            style: theme.textTheme.labelLarge?.copyWith(
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          DsCard(
            key: const Key('onboarding_perm_notifications'),
            onTap: _checking || _opening ? null : _openNotifications,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.notifications_outlined, color: palette.primary),
                const SizedBox(width: DsSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        OnboardingPermissionsStep.notificationsTitle,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: DsSpacing.xs),
                      Text(
                        OnboardingPermissionsStep.notificationsWhy,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: DsSpacing.sm),
                if (_checking)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  DsStatusPill(
                    key: const Key('onboarding_perm_notifications_status'),
                    label: switch (_notifications.status) {
                      OnboardingPermissionStatus.enabled =>
                        OnboardingPermissionsStep.enabledLabel,
                      OnboardingPermissionStatus.notEnabled =>
                        OnboardingPermissionsStep.notificationsOptionalLabel,
                      OnboardingPermissionStatus.unknown =>
                        OnboardingPermissionsStep.unknownLabel,
                    },
                    tone: switch (_notifications.status) {
                      OnboardingPermissionStatus.enabled => DsTone.success,
                      OnboardingPermissionStatus.notEnabled => DsTone.neutral,
                      OnboardingPermissionStatus.unknown => DsTone.warning,
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.md),
        ],
        if (message != null) ...<Widget>[
          Text(message, style: TextStyle(color: palette.danger)),
          const SizedBox(height: DsSpacing.md),
        ],
        if (!_checking && !_coreReady) ...<Widget>[
          Text(
            OnboardingPermissionsStep.incompleteNote,
            style: theme.textTheme.bodySmall?.copyWith(color: palette.warning),
          ),
          const SizedBox(height: DsSpacing.md),
        ],
        const SizedBox(height: DsSpacing.sm),
        DsButton(
          label: !_checking && _coreReady
              ? OnboardingPermissionsStep.continueLabel
              : OnboardingPermissionsStep.skipLabel,
          variant: !_checking && _coreReady && _current == null
              ? DsButtonVariant.primary
              : DsButtonVariant.outline,
          expand: true,
          onPressed: _checking || _opening ? null : widget.onContinue,
        ),
      ],
    );
  }
  Widget _buildProgress(ThemeData theme, DsPalette palette) {
    final int total = _required.length;
    final int done = _checking ? 0 : _requiredAllowedCount;
    return Column(
      key: const Key('onboarding_setup_progress'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(DsRadii.md),
          child: LinearProgressIndicator(
            value: _checking ? null : done / total,
            minHeight: 6,
            backgroundColor: palette.border,
            color: palette.success,
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          _checking
              ? 'Checking…'
              : OnboardingPermissionsStep.progressLabel(done, total),
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.textSecondary,
          ),
        ),
      ],
    );
  }

  /// The single current step (or the all-allowed card).
  Widget _buildCurrent(ThemeData theme, DsPalette palette) {
    final OnboardingPermission? p = _current;
    if (p == null) {
      return DsCard(
        key: const Key('onboarding_setup_complete'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.check_circle, color: palette.success),
            const SizedBox(width: DsSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    OnboardingPermissionsStep.allSetTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    OnboardingPermissionsStep.allSetMessage,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final List<OnboardingPermission> required = _required;
    final OnboardingPermissionStatus status = _of(p.id);
    final int returns = _notEnabledReturns[p.id] ?? 0;
    final bool trouble =
        returns >= 2 && status == OnboardingPermissionStatus.notEnabled;
    final bool helpOpen = trouble && _helpOpenFor == p.id;
    final String? helpMessage = _helpMessage;
    final bool busy = _checking || _opening;
    return DsCard(
      key: const Key('onboarding_current_step'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            p.required
                ? OnboardingPermissionsStep.stepLabel(
                    required.indexOf(p) + 1, required.length)
                : OnboardingPermissionsStep.extraStepLabel,
            key: const Key('onboarding_current_step_label'),
            style: theme.textTheme.labelLarge?.copyWith(
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          Row(
            children: <Widget>[
              Icon(p.icon, color: palette.primary),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  p.title,
                  key: const Key('onboarding_current_step_title'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (!p.required)
                const DsStatusPill(
                  label: OnboardingPermissionsStep.recommendedTag,
                  tone: DsTone.neutral,
                ),
            ],
          ),
          const SizedBox(height: DsSpacing.sm),
          Text(p.why, style: theme.textTheme.bodyMedium),
          const SizedBox(height: DsSpacing.sm),
          Text(
            OnboardingPermissionsStep.howTo[p.id] ?? '',
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
            ),
          ),
          if (status == OnboardingPermissionStatus.unknown) ...<Widget>[
            const SizedBox(height: DsSpacing.md),
            Text(
              OnboardingPermissionsStep.unknownNote,
              key: const Key('onboarding_current_unknown'),
              style:
                  theme.textTheme.bodySmall?.copyWith(color: palette.warning),
            ),
          ],
          if (trouble) ...<Widget>[
            const SizedBox(height: DsSpacing.md),
            Container(
              key: const Key('onboarding_not_enabled_help'),
              width: double.infinity,
              padding: const EdgeInsets.all(DsSpacing.md),
              decoration: BoxDecoration(
                color: palette.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(DsRadii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    OnboardingPermissionsStep.notEnabledTitle,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    OnboardingPermissionsStep.notEnabledMessage,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: DsSpacing.md),
          DsButton(
            key: const Key('onboarding_current_action'),
            label: returns > 0
                ? OnboardingPermissionsStep.tryAgainLabel
                : OnboardingPermissionsStep.allowLabel,
            expand: true,
            onPressed: busy ? null : () => _open(p),
          ),
          if (status == OnboardingPermissionStatus.unknown) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            DsButton(
              key: const Key('onboarding_current_check_again'),
              label: OnboardingPermissionsStep.checkAgainLabel,
              variant: DsButtonVariant.ghost,
              expand: true,
              onPressed: busy ? null : _refresh,
            ),
          ],
          if (trouble) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            DsButton(
              key: const Key('onboarding_setup_help_toggle'),
              label: helpOpen
                  ? OnboardingPermissionsStep.hideHelpLabel
                  : OnboardingPermissionsStep.helpLabel,
              variant: DsButtonVariant.ghost,
              expand: true,
              onPressed: () => setState(() {
                _helpOpenFor = helpOpen ? null : p.id;
                _helpMessage = null;
              }),
            ),
          ],
          if (helpOpen) _buildHelp(theme, palette, p, helpMessage),
        ],
      ),
    );
  }

  Widget _buildHelp(
    ThemeData theme,
    DsPalette palette,
    OnboardingPermission p,
    String? helpMessage,
  ) {
    final TextStyle? body = theme.textTheme.bodySmall;
    final TextStyle? muted = body?.copyWith(color: palette.textSecondary);
    return Padding(
      key: const Key('onboarding_setup_help'),
      padding: const EdgeInsets.only(top: DsSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(OnboardingPermissionsStep.helpGeneral[p.id] ?? '', style: body),
          if (_restrictedHelpApplies) ...<Widget>[
            const SizedBox(height: DsSpacing.md),
            Text(
              OnboardingPermissionsStep.restrictedHeading,
              key: const Key('onboarding_restricted_help'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(OnboardingPermissionsStep.restrictedSteps, style: body),
            const SizedBox(height: DsSpacing.xs),
            Text(OnboardingPermissionsStep.restrictedTrust, style: muted),
            const SizedBox(height: DsSpacing.sm),
            DsButton(
              key: const Key('onboarding_open_app_info'),
              label: OnboardingPermissionsStep.openAppInfoLabel,
              variant: DsButtonVariant.secondary,
              expand: true,
              onPressed: _opening ? null : _openAppInfo,
            ),
            const SizedBox(height: DsSpacing.sm),
            Text(OnboardingPermissionsStep.restrictedAlternative, style: muted),
          ],
          if (helpMessage != null) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            Text(
              helpMessage,
              key: const Key('onboarding_help_message'),
              style: body?.copyWith(color: palette.danger),
            ),
          ],
        ],
      ),
    );
  }
}
