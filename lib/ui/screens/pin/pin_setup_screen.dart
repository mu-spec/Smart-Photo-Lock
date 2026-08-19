import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../widgets/entry_shake.dart';

/// Steps of the PIN setup flow.
enum PinSetupStep {
  chooseLength,
  enter,
  confirm,

  /// Confirmation did not match (Phase 2C): the user decides whether to
  /// re-enter only the confirmation or start the PIN over. Nothing is
  /// saved at this point.
  mismatch,
  success,
}

/// Initial PIN setup screen.
///
/// **Confirmation is mandatory** — enrollment runs only after the second
/// entry matches the first (Phase 2C). Mismatches land on a dedicated
/// retry state with two clean choices:
///
///  * **Re-confirm PIN** — keeps the first entry and re-asks only the
///    confirmation (the user suspects a typo in the second entry);
///  * **Start over** — clears everything and restarts at the first entry.
///
/// A shake animation and red error dots make a mismatch impossible to miss,
/// and no partial credential is ever saved.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({
    super.key,
    this.credentialManager,
    this.initialLength,
  }) : assert(initialLength == null || initialLength == 4 || initialLength == 6);

  /// Overrides the manager resolved from [AppScope] (tests/previews).
  final CredentialManager? credentialManager;

  /// Skips the length step when a length is already known
  /// (used by the future change-PIN flow).
  final int? initialLength;

  static const String chooseLengthTitle = 'Choose PIN length';
  static const String enterPinTitle = 'Enter your new PIN';
  static const String confirmPinTitle = 'Confirm your PIN';
  static const String successTitle = 'PIN is set';

  static const String mismatchTitle = "PINs don't match";
  static const String mismatchMessage =
      'The confirmation did not match the PIN you entered. '
      'Nothing was saved.';
  static const String reconfirmLabel = 'Re-confirm PIN';
  static const String startOverLabel = 'Start over';
  static const String saveFailedMessage =
      'Could not save your PIN. Please try again.';

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen>
    with SingleTickerProviderStateMixin, EntryShakeMixin {
  PinSetupStep _step = PinSetupStep.chooseLength;
  int? _length;
  String _entered = '';
  String? _firstPin;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    initShake();

    final int? initial = widget.initialLength;
    if (initial != null) {
      _length = initial;
      _step = PinSetupStep.enter;
    }
  }

  @override
  void dispose() {
    disposeShake();
    super.dispose();
  }

  CredentialManager get _manager =>
      widget.credentialManager ?? AppScope.read(context)!.auth;

  void _chooseLength(int length) {
    setState(() {
      _length = length;
      _step = PinSetupStep.enter;
      _entered = '';
      _firstPin = null;
      _error = null;
    });
  }

  void _goBackToLengthChoice() {
    setState(() {
      _step = PinSetupStep.chooseLength;
      _entered = '';
      _firstPin = null;
      _error = null;
    });
  }

  /// Phase 2C: keep the first PIN, only redo the confirmation.
  void _reconfirm() {
    setState(() {
      _step = PinSetupStep.confirm;
      _entered = '';
      _error = null;
    });
  }

  /// Phase 2C: drop everything and restart from the first entry.
  void _startOver() {
    setState(() {
      _step = PinSetupStep.enter;
      _entered = '';
      _firstPin = null;
      _error = null;
    });
  }

  void _onDigit(String digit) {
    final int? length = _length;
    if (_saving || length == null) {
      return;
    }
    if (_step != PinSetupStep.enter && _step != PinSetupStep.confirm) {
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
      _onCompleted();
    }
  }

  void _onDelete() {
    if (_saving || _entered.isEmpty) {
      return;
    }
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  void _onDeleteAll() {
    if (_saving) {
      return;
    }
    setState(() => _entered = '');
  }

  /// Fires automatically when the entry reaches the target length.
  Future<void> _onCompleted() async {
    // Let the last dot paint before switching steps.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted || _saving) {
      return;
    }

    if (_step == PinSetupStep.enter) {
      setState(() {
        _firstPin = _entered;
        _step = PinSetupStep.confirm;
        _entered = '';
      });
      return;
    }

    // Confirmation step: nothing is saved unless it matches (Phase 2C).
    if (_entered == _firstPin) {
      await _enroll(_entered);
    } else {
      shake();
      setState(() {
        _step = PinSetupStep.mismatch;
        _entered = '';
      });
    }
  }

  Future<void> _enroll(String pin) async {
    setState(() => _saving = true);
    final result = await _manager.enrollPin(pin);
    if (!mounted) {
      return;
    }

    if (result.isSuccess) {
      // Best-effort: the initial setup is now complete.
      final prefs = AppScope.read(context)?.preferences;
      if (prefs != null) {
        try {
          await prefs.setOnboardingCompleted(true);
        } catch (_) {
          // Non-critical — just a hint for later phases.
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _step = PinSetupStep.success;
        // Phase 2D hygiene: drop the raw PIN from widget state the moment
        // enrollment completes — only the derived hash exists in storage.
        _entered = '';
        _firstPin = null;
      });
    } else {
      setState(() {
        _saving = false;
        _error = PinSetupScreen.saveFailedMessage;
        _step = PinSetupStep.enter;
        _entered = '';
        _firstPin = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up PIN')),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: switch (_step) {
            PinSetupStep.chooseLength => _buildChooseLength(),
            PinSetupStep.enter => _buildEntry(confirming: false),
            PinSetupStep.confirm => _buildEntry(confirming: true),
            PinSetupStep.mismatch => _buildMismatch(),
            PinSetupStep.success => _buildSuccess(),
          },
        ),
      ),
    );
  }

  // -- steps ---------------------------------------------------------------

  Widget _buildChooseLength() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('choose_length'),
      padding: DsInsets.screen,
      children: <Widget>[
        const SizedBox(height: DsSpacing.sm),
        Text(
          PinSetupScreen.chooseLengthTitle,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: DsSpacing.sm),
        Text(
          'Pick the length of the PIN you will enter to unlock '
          'protected apps.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette.textSecondary,
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        _LengthCard(
          length: 4,
          subtitle: 'Quickest to enter',
          selected: _length == 4,
          onTap: () => _chooseLength(4),
        ),
        const SizedBox(height: DsSpacing.md),
        _LengthCard(
          length: 6,
          subtitle: 'More combinations',
          selected: _length == 6,
          onTap: () => _chooseLength(6),
        ),
      ],
    );
  }

  Widget _buildEntry({required bool confirming}) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final int length = _length!;
    return ListView(
      key: ValueKey<String>(confirming ? 'confirm' : 'enter'),
      padding: DsInsets.screen,
      children: <Widget>[
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            confirming
                ? PinSetupScreen.confirmPinTitle
                : PinSetupScreen.enterPinTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        Center(
          child: Text(
            confirming
                ? 'Re-enter your $length-digit PIN'
                : 'Enter your new $length-digit PIN',
            style: theme.textTheme.bodyMedium?.copyWith(
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
          enabled: !_saving,
        ),
        if (_saving) ...<Widget>[
          const SizedBox(height: DsSpacing.lg),
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ],
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: DsButton(
            label: 'Change PIN length',
            variant: DsButtonVariant.ghost,
            size: DsButtonSize.small,
            onPressed: _saving ? null : _goBackToLengthChoice,
          ),
        ),
      ],
    );
  }

  /// Phase 2C: dedicated mismatch state — nothing was saved.
  Widget _buildMismatch() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final int length = _length!;
    return ListView(
      key: const ValueKey<String>('mismatch'),
      padding: DsInsets.screen,
      children: <Widget>[
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: palette.danger.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: palette.danger.withValues(alpha: 0.4)),
            ),
            child: Icon(Icons.sync_problem, size: 36, color: palette.danger),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            PinSetupScreen.mismatchTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            PinSetupScreen.mismatchMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: shakeWrap(DsPinDots(filled: 0, total: length, error: true)),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: PinSetupScreen.reconfirmLabel,
          expand: true,
          onPressed: _reconfirm,
        ),
        const SizedBox(height: DsSpacing.md),
        DsButton(
          label: PinSetupScreen.startOverLabel,
          variant: DsButtonVariant.outline,
          expand: true,
          onPressed: _startOver,
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('success'),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: <Widget>[
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: palette.success.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: palette.success.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(Icons.check_rounded, size: 44, color: palette.success),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            PinSetupScreen.successTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            'Your ${_length}-digit PIN protects your apps from now on.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: 'Done',
          expand: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

/// Length selection card (4 or 6 digits).
class _LengthCard extends StatelessWidget {
  const _LengthCard({
    required this.length,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final int length;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    return DsCard(
      title: '$length-digit PIN',
      subtitle: subtitle,
      color: selected ? palette.primary.withValues(alpha: 0.12) : null,
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? palette.primary : palette.border,
      ),
      onTap: onTap,
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
