import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_result.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../../security/credentials/pattern_policy.dart';
import '../../widgets/entry_shake.dart';

/// Internal presentation states of the pattern unlock screen.
enum _UnlockView { loading, ready, noCredential, lockedOut }

/// Full-screen pattern authentication (Phase 2I).
///
/// Uses the **saved pattern**: the exact ordered node sequence drawn at
/// setup must be reproduced — direction and order are part of the
/// credential (Android-style). Every attempt flows through
/// [CredentialManager] — wrong patterns count toward the escalating
/// lockout (2F), lockouts persist across restarts, and only the derived
/// hash is ever consulted (2D).
///
/// Outcomes:
///  * correct pattern → pops with `true` (access granted);
///  * wrong pattern → inline error with remaining attempts + shake;
///  * too-short draw → inline hint (min 4 dots);
///  * lockout → live countdown, grid disabled until the cooldown expires;
///    persisted lockouts are picked up as soon as the screen opens;
///  * no pattern configured → guided recovery screen.
class PatternUnlockScreen extends StatefulWidget {
  const PatternUnlockScreen({
    super.key,
    this.credentialManager,
    this.title = 'Pattern unlock',
    this.now,
  });

  /// Overrides the manager resolved from [AppScope] (tests/previews).
  final CredentialManager? credentialManager;

  /// Header title.
  final String title;

  /// Clock seam for tests (defaults to [DateTime.now]).
  final DateTime Function()? now;

  static const String readyHint = 'Draw your pattern to unlock';
  static const String wrongPatternPrefix = 'Incorrect pattern';
  static const String verifyFailedMessage =
      'Could not verify your pattern. Please try again.';
  static const String lockedOutTitle = 'Too many attempts';
  static const String lockedOutMessage = 'Try again in';
  static const String noCredentialTitle = 'No pattern configured';
  static const String noCredentialMessage = 'Set up a pattern before unlocking.';
  static const String setUpPatternLabel = 'Set up pattern';
  static const String backLabel = 'Back';
  static const String tooShortMessage = 'Connect at least 4 dots';
  static const String clearLabel = 'Clear';

  /// Fixed grid size so the geometry is predictable (and testable).
  static const double gridSize = 280;

  @override
  State<PatternUnlockScreen> createState() => _PatternUnlockScreenState();
}

class _PatternUnlockScreenState extends State<PatternUnlockScreen>
    with SingleTickerProviderStateMixin, EntryShakeMixin {
  _UnlockView _view = _UnlockView.loading;
  List<int> _nodes = <int>[];
  bool _verifying = false;
  String? _error;
  DateTime? _lockoutUntil;
  Duration _lockoutRemaining = Duration.zero;
  int _lockoutStreak = 0;
  Timer? _timer;

  // Phase 2K — pattern trail visibility.
  bool _patternVisible = true;

  // Phase 5G — biometric shortcut (offered only when the user enabled
  // biometric unlock in Security settings).
  bool _biometricEnabled = false;

  CredentialManager get _manager =>
      widget.credentialManager ?? AppScope.read(context)!.auth;

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    initShake();
    _loadStatus();
  }

  @override
  void dispose() {
    _timer?.cancel();
    disposeShake();
    super.dispose();
  }

  /// Reads the credential configuration once when the screen opens:
  /// whether a pattern is enrolled, and any lockout already active.
  Future<void> _loadStatus() async {
    final state = (await _manager.status()).valueOrNull;
    if (!mounted) {
      return;
    }
    if (state == null || !state.hasEnrolled(AuthType.pattern)) {
      setState(() => _view = _UnlockView.noCredential);
      return;
    }
    _patternVisible = state.patternVisibilityEnabled;
    // Phase 5G: biometric is an accelerator on the challenge surface —
    // offered only when the user explicitly enabled it in Security.
    _biometricEnabled = state.hasEnrolled(AuthType.biometric);
    final DateTime? lockout = state.lockedOutUntil;
    if (lockout != null && _now().isBefore(lockout)) {
      _startLockout(lockout, streak: state.lockoutStreak);
    } else {
      setState(() => _view = _UnlockView.ready);
    }
  }

  // -- input ---------------------------------------------------------------

  void _onNodeAdded(List<int> sequence) {
    if (_verifying || _view != _UnlockView.ready) {
      return;
    }
    setState(() {
      _nodes = sequence;
      _error = null;
    });
  }

  /// Pointer lifted: validate, then authenticate.
  void _onDragEnd() {
    if (_verifying || _view != _UnlockView.ready) {
      return;
    }
    final List<int> drawn = _nodes;
    if (PatternPolicy.defaults.validate(drawn) != PatternValidation.valid) {
      shake();
      setState(() {
        _error = PatternUnlockScreen.tooShortMessage;
        _nodes = <int>[];
      });
      return;
    }
    _submit(drawn);
  }

  void _clear() {
    if (_verifying) {
      return;
    }
    setState(() => _nodes = <int>[]);
  }

  // -- biometric (Phase 5G) -------------------------------------------------

  /// Maps biometric failures onto the inline error message (mirrors the
  /// PIN unlock screen's mapping).
  String _biometricError(AuthFailure failure) => switch (failure.reason) {
        AuthFailureReason.notConfigured =>
          'Enable biometric unlock in Security settings.',
        AuthFailureReason.notAvailable =>
          'Biometric authentication is not available.',
        AuthFailureReason.wrongCredential => failure.remainingAttempts > 0
            ? 'Biometric failed — ${failure.remainingAttempts} attempts left.'
            : 'Biometric failed.',
        AuthFailureReason.cancelled => 'Biometric cancelled.',
        AuthFailureReason.noCredentialEnrolled => 'No pattern configured.',
        AuthFailureReason.invalidInput => 'Biometric failed.',
      };

  Future<void> _onBiometric() async {
    if (_verifying || _view != _UnlockView.ready) {
      return;
    }
    setState(() => _verifying = true);
    final result =
        await _manager.authenticateBiometric(reason: 'Unlock Smart App Lock');
    if (!mounted) {
      return;
    }
    final outcome = result.valueOrNull;

    if (outcome is AuthSuccess) {
      Navigator.of(context).pop(true);
      return;
    }
    if (outcome is AuthLockedOut) {
      _startLockout(outcome.retryAt, streak: outcome.lockoutStreak);
      return;
    }
    if (outcome is AuthFailure) {
      setState(() {
        _verifying = false;
        _nodes = <int>[];
        _error = _biometricError(outcome);
      });
      shake();
      return;
    }

    // Service failure (fail-closed): generic message, retry.
    setState(() {
      _verifying = false;
      _nodes = <int>[];
      _error = PatternUnlockScreen.verifyFailedMessage;
    });
    shake();
  }

  // -- authentication ------------------------------------------------------

  Future<void> _submit(List<int> nodes) async {
    setState(() => _verifying = true);
    final result = await _manager.authenticatePattern(nodes);
    if (!mounted) {
      return;
    }
    final outcome = result.valueOrNull;

    if (outcome is AuthSuccess) {
      Navigator.of(context).pop(true);
      return;
    }
    if (outcome is AuthLockedOut) {
      _startLockout(outcome.retryAt, streak: outcome.lockoutStreak);
      return;
    }
    if (outcome is AuthFailure) {
      if (outcome.reason == AuthFailureReason.noCredentialEnrolled) {
        setState(() {
          _view = _UnlockView.noCredential;
          _verifying = false;
          _nodes = <int>[];
        });
        return;
      }
      setState(() {
        _verifying = false;
        _nodes = <int>[];
        _error = outcome.remainingAttempts > 0
            ? '${PatternUnlockScreen.wrongPatternPrefix} — '
                '${outcome.remainingAttempts} attempts left.'
            : PatternUnlockScreen.wrongPatternPrefix;
      });
      shake();
      return;
    }

    // Storage/crypto failure (fail-closed path): generic message, retry.
    setState(() {
      _verifying = false;
      _nodes = <int>[];
      _error = PatternUnlockScreen.verifyFailedMessage;
    });
    shake();
  }

  // -- lockout -------------------------------------------------------------

  void _startLockout(DateTime until, {int streak = 0}) {
    _timer?.cancel();
    setState(() {
      _view = _UnlockView.lockedOut;
      _lockoutUntil = until;
      _lockoutRemaining = until.difference(_now());
      _lockoutStreak = streak;
      _nodes = <int>[];
      _verifying = false;
      _error = null;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final DateTime until = _lockoutUntil!;
    final Duration remaining = until.difference(_now());
    if (remaining <= Duration.zero) {
      _timer?.cancel();
      setState(() {
        _view = _UnlockView.ready;
        _lockoutUntil = null;
        _lockoutRemaining = Duration.zero;
      });
    } else {
      setState(() => _lockoutRemaining = remaining);
    }
  }

  String _formatCountdown(Duration d) {
    final int total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final int minutes = total ~/ 60;
    final int seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // -- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: switch (_view) {
            _UnlockView.loading => const Center(
                key: ValueKey<String>('loading'),
                child: CircularProgressIndicator(),
              ),
            _UnlockView.noCredential => _buildNoCredential(),
            _UnlockView.lockedOut => _buildLockedOut(),
            _UnlockView.ready => _buildEntry(),
          },
        ),
      ),
    );
  }

  Widget _buildEntry() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('entry'),
      padding: DsInsets.screen,
      children: <Widget>[
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            PatternUnlockScreen.readyHint,
            style: theme.textTheme.titleMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        // Fixed-height error slot: the banner must NEVER shift the grid
        // mid-stroke. Without this, the first node of the next attempt
        // clears the error, the banner collapses, the grid jumps, and
        // the rest of the stroke misses every node.
        SizedBox(
          height: 56,
          child: _error == null
              ? null
              : Center(child: _ErrorBanner(message: _error!)),
        ),
        const SizedBox(height: DsSpacing.md),
        Center(
          child: shakeWrap(
            SizedBox(
              width: PatternUnlockScreen.gridSize,
              height: PatternUnlockScreen.gridSize,
              child: DsPatternGrid(
                nodes: _nodes,
                onNodeAdded: _onNodeAdded,
                onDragEnd: _onDragEnd,
                enabled: !_verifying,
                showFeedback: _patternVisible,
              ),
            ),
          ),
        ),
        if (!_patternVisible) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Center(
            child: Text(
              'Pattern trail hidden for privacy',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: DsButton(
            label: PatternUnlockScreen.clearLabel,
            variant: DsButtonVariant.ghost,
            size: DsButtonSize.small,
            onPressed: _verifying ? null : _clear,
          ),
        ),
        // Phase 5G: biometric accelerator — same contract as the PIN
        // unlock screen (button only when the user opted in).
        if (_biometricEnabled) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Center(
            child: DsButton(
              key: const Key('pattern_key_biometric'),
              label: 'Use fingerprint',
              variant: DsButtonVariant.secondary,
              size: DsButtonSize.small,
              icon: Icons.fingerprint,
              onPressed: _verifying ? null : _onBiometric,
            ),
          ),
        ],
        if (_verifying) ...<Widget>[
          const SizedBox(height: DsSpacing.lg),
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLockedOut() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('locked_out'),
      padding: DsInsets.screen,
      children: <Widget>[
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: palette.warning.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: palette.warning.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(Icons.lock_clock, size: 36, color: palette.warning),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            PatternUnlockScreen.lockedOutTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            '${PatternUnlockScreen.lockedOutMessage} '
            '${_formatCountdown(_lockoutRemaining)}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: palette.textPrimary,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (_lockoutStreak >= 2) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Center(
            child: Text(
              'Cooldown increases with repeated failures.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.warning,
              ),
            ),
          ),
        ],
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: SizedBox(
            width: PatternUnlockScreen.gridSize,
            height: PatternUnlockScreen.gridSize,
            child: const DsPatternGrid(
              nodes: <int>[],
              enabled: false,
              error: true,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: DsButton(
            label: PatternUnlockScreen.backLabel,
            variant: DsButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ),
      ],
    );
  }

  Widget _buildNoCredential() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('no_credential'),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: <Widget>[
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: palette.warning.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: palette.warning.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(Icons.lock_open, size: 44, color: palette.warning),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            PatternUnlockScreen.noCredentialTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            PatternUnlockScreen.noCredentialMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: PatternUnlockScreen.setUpPatternLabel,
          expand: true,
          // Phase 5I: the setup flow is pushed NORMALLY (not as a
          // replacement). With pushReplacement, the setup screen's own
          // pop(true) — an ENROLLMENT confirmation — would resolve this
          // route's future with `true`, which the lock host reads as
          // "authenticated" and would grant an unlock session without
          // any authentication ever happening. Enrollment is NOT
          // authentication: the unlock route stays on the stack, its
          // future completes only when THIS screen pops, and after
          // setup the user must still verify the credential.
          onPressed: () async {
            await Navigator.of(context).pushNamed(RouteNames.patternSetup);
            if (mounted) {
              _loadStatus();
            }
          },
        ),
        const SizedBox(height: DsSpacing.md),
        DsButton(
          label: PatternUnlockScreen.backLabel,
          variant: DsButtonVariant.outline,
          expand: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}

/// Inline error banner shown above the grid.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DsRadii.md),
        border: Border.all(color: palette.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: palette.danger),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: palette.danger),
            ),
          ),
        ],
      ),
    );
  }
}
