import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_result.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../widgets/entry_shake.dart';

/// Internal presentation states of the unlock screen.
enum _UnlockView { loading, ready, noCredential, lockedOut }

/// Full-screen PIN authentication (Phase 2E).
///
/// Uses the **configured PIN**: the enrolled credential's recorded length
/// drives the dots, and the entry auto-submits at that length through
/// [CredentialManager] (which enforces lockouts and verifies against the
/// stored derived hash — the raw PIN never leaves this screen).
///
/// Outcomes:
///  * correct PIN → pops with `true` (access granted);
///  * wrong PIN → inline error with remaining attempts + shake;
///  * lockout → live countdown, pad disabled until the cooldown expires;
///    persisted lockouts are picked up as soon as the screen opens;
///  * no PIN configured → guided recovery screen.
class PinUnlockScreen extends StatefulWidget {
  const PinUnlockScreen({
    super.key,
    this.credentialManager,
    this.title = 'Enter your PIN',
    this.now,
    this.random,
  });

  /// Overrides the manager resolved from [AppScope] (tests/previews).
  final CredentialManager? credentialManager;

  /// Header title.
  final String title;

  /// Clock seam for tests (defaults to [DateTime.now]).
  final DateTime Function()? now;

  /// RNG seam for the randomized keypad (Phase 2G) — tests inject a seeded
  /// [math.Random] for deterministic shuffles.
  final math.Random? random;

  static const String wrongPinPrefix = 'Incorrect PIN';
  static const String verifyFailedMessage =
      'Could not verify your PIN. Please try again.';
  static const String lockedOutTitle = 'Too many attempts';
  static const String lockedOutMessage = 'Try again in';
  static const String noCredentialTitle = 'No PIN configured';
  static const String noCredentialMessage =
      'Set up a PIN before unlocking.';
  static const String setUpPinLabel = 'Set up PIN';
  static const String backLabel = 'Back';

  @override
  State<PinUnlockScreen> createState() => _PinUnlockScreenState();
}

class _PinUnlockScreenState extends State<PinUnlockScreen>
    with SingleTickerProviderStateMixin, EntryShakeMixin {
  _UnlockView _view = _UnlockView.loading;
  int? _pinLength;
  String _entered = '';
  bool _verifying = false;
  String? _error;
  DateTime? _lockoutUntil;
  Duration _lockoutRemaining = Duration.zero;
  int _lockoutStreak = 0;
  Timer? _timer;

  // Phase 2G — randomized keypad.
  bool _randomized = false;
  List<String> _digitOrder = DsPinPad.defaultDigitOrder;
  late final math.Random _random;

  // Phase 2J — biometric shortcut.
  bool _biometricEnabled = false;

  CredentialManager get _manager =>
      widget.credentialManager ?? AppScope.read(context)!.auth;

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    initShake();
    _random = widget.random ?? math.Random();
    _loadStatus();
  }

  @override
  void dispose() {
    _timer?.cancel();
    disposeShake();
    super.dispose();
  }

  /// Reads the credential configuration once when the screen opens:
  /// enrolled PIN length, and any lockout that is already active.
  Future<void> _loadStatus() async {
    final state = (await _manager.status()).valueOrNull;
    if (!mounted) {
      return;
    }
    final int? length = state?.pinLength;
    if (state == null ||
        !state.hasEnrolled(AuthType.pin) ||
        length == null) {
      setState(() => _view = _UnlockView.noCredential);
      return;
    }
    _pinLength = length;
    _randomized = state.randomizedKeypadEnabled;
    if (_randomized) {
      _digitOrder = shuffledDigitOrder(_random);
    }
    _biometricEnabled = state.hasEnrolled(AuthType.biometric);
    final DateTime? lockout = state.lockedOutUntil;
    if (lockout != null && _now().isBefore(lockout)) {
      _startLockout(lockout, streak: state.lockoutStreak);
    } else {
      setState(() => _view = _UnlockView.ready);
    }
  }

  // -- input ---------------------------------------------------------------

  void _onDigit(String digit) {
    final int? length = _pinLength;
    if (_verifying || length == null || _view != _UnlockView.ready) {
      return;
    }
    if (_entered.length >= length) {
      return;
    }
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == length) {
      _submit();
    }
  }

  void _onDelete() {
    if (_verifying || _entered.isEmpty) {
      return;
    }
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  void _onDeleteAll() {
    if (_verifying) {
      return;
    }
    setState(() => _entered = '');
  }

  // -- verification --------------------------------------------------------

  Future<void> _submit() async {
    setState(() => _verifying = true);
    final result = await _manager.authenticatePin(_entered);
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
          _entered = '';
        });
        return;
      }
      setState(() {
        _verifying = false;
        _entered = '';
        _error = outcome.remainingAttempts > 0
            ? '${PinUnlockScreen.wrongPinPrefix} — '
                '${outcome.remainingAttempts} attempts left.'
            : PinUnlockScreen.wrongPinPrefix;
        if (_randomized) {
          _digitOrder = shuffledDigitOrder(_random);
        }
      });
      shake();
      return;
    }

    // Storage/crypto failure (fail-closed path): generic message, retry.
    setState(() {
      _verifying = false;
      _entered = '';
      _error = PinUnlockScreen.verifyFailedMessage;
      if (_randomized) {
        _digitOrder = shuffledDigitOrder(_random);
      }
    });
    shake();
  }

  // -- biometric (Phase 2J) -------------------------------------------------

  /// Maps biometric failures onto the inline error message.
  String _biometricError(AuthFailure failure) => switch (failure.reason) {
        AuthFailureReason.notConfigured =>
          'Enable biometric unlock in Security settings.',
        AuthFailureReason.notAvailable =>
          'Biometric authentication is not available.',
        AuthFailureReason.wrongCredential => failure.remainingAttempts > 0
            ? 'Biometric failed — ${failure.remainingAttempts} attempts left.'
            : 'Biometric failed.',
        AuthFailureReason.cancelled => 'Biometric cancelled.',
        AuthFailureReason.noCredentialEnrolled => 'No PIN configured.',
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
        _entered = '';
        _error = _biometricError(outcome);
      });
      shake();
      return;
    }

    // Service failure (fail-closed): generic message, retry.
    setState(() {
      _verifying = false;
      _entered = '';
      _error = PinUnlockScreen.verifyFailedMessage;
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
      _entered = '';
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
        if (_randomized) {
          // Fresh layout for the new attempt window.
          _digitOrder = shuffledDigitOrder(_random);
        }
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
    // Phase 5I hardening: the unlock route ALWAYS resolves with an
    // explicit non-unlock result when dismissed. System Back, the
    // AppBar back button and predictive-back all route through
    // Navigator.maybePop, which — with canPop:false — is vetoed and
    // reported via onPopInvokedWithResult; this screen then pops
    // itself with `false`. Without this, those dismissal paths resolve
    // the route's future with `null`, which callers (the lock
    // challenge host, the change-PIN verify step) must treat as "not
    // unlocked" but cannot distinguish from an unresolved outcome.
    // Enrollment is never authentication: even after the guided
    // recovery/setup flow, only a successful credential verification
    // pops `true`.
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        Navigator.of(context).pop(false);
      },
      child: Scaffold(
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
      ),
    );
  }

  Widget _buildEntry() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final int length = _pinLength!;
    return ListView(
      key: const ValueKey<String>('entry'),
      padding: DsInsets.screen,
      children: <Widget>[
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            'Enter your $length-digit PIN',
            style: theme.textTheme.titleMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: DsSpacing.lg),
          _ErrorBanner(message: _error!),
        ],
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: shakeWrap(DsPinDots(filled: _entered.length, total: length)),
        ),
        const SizedBox(height: DsSpacing.xl),
        DsPinPad(
          onDigit: _onDigit,
          onDelete: _onDelete,
          onDeleteAll: _onDeleteAll,
          enabled: !_verifying,
          digitOrder: _digitOrder,
          showBiometric: _biometricEnabled,
          onBiometric: _onBiometric,
        ),
        if (_biometricEnabled) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Center(
            child: Text(
              'Or use your fingerprint',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
        if (_randomized) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Center(
            child: Text(
              'Keypad order randomized',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
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
    final int length = _pinLength ?? 4;
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
            PinUnlockScreen.lockedOutTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            '${PinUnlockScreen.lockedOutMessage} '
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
        Center(child: DsPinDots(filled: 0, total: length, error: true)),
        const SizedBox(height: DsSpacing.xl),
        DsPinPad(
          onDigit: (_) {},
          onDelete: () {},
          enabled: false,
          digitOrder: _digitOrder,
        ),
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: DsButton(
            label: PinUnlockScreen.backLabel,
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
            PinUnlockScreen.noCredentialTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            PinUnlockScreen.noCredentialMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: PinUnlockScreen.setUpPinLabel,
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
            await Navigator.of(context).pushNamed(RouteNames.pinSetup);
            if (mounted) {
              _loadStatus();
            }
          },
        ),
        const SizedBox(height: DsSpacing.md),
        DsButton(
          label: PinUnlockScreen.backLabel,
          variant: DsButtonVariant.outline,
          expand: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}

/// Inline error banner shown above the dots.
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
