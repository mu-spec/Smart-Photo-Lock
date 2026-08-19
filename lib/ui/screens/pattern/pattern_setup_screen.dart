import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../../security/credentials/pattern_codec.dart';
import '../../../security/credentials/pattern_policy.dart';
import '../../widgets/entry_shake.dart';

/// Steps of the pattern setup flow.
enum PatternSetupStep { enter, confirm, mismatch, success }

/// Pattern creation and confirmation screen (Phase 2H).
///
/// Draw → confirm → enroll. Confirmation is mandatory: enrollment runs only
/// when the redrawn sequence matches the first one **exactly, in order**
/// (direction-sensitive via [PatternCodec.matches]). Mismatches land on a
/// dedicated state with Re-confirm / Start over choices — mirroring the PIN
/// flow (2C) — and nothing is saved until a confirmed match. Minimum 4
/// dots, enforced inline.
class PatternSetupScreen extends StatefulWidget {
  const PatternSetupScreen({
    super.key,
    this.credentialManager,
    this.title = 'Set up pattern',
  });

  /// Overrides the manager resolved from [AppScope] (tests/previews).
  final CredentialManager? credentialManager;

  /// App-bar title (the change-pattern flow passes a different one).
  final String title;

  static const String enterTitle = 'Draw your new pattern';
  static const String confirmTitle = 'Confirm your pattern';
  static const String successTitle = 'Pattern is set';
  static const String mismatchTitle = "Patterns don't match";
  static const String mismatchMessage =
      'The confirmation did not match the pattern you drew. '
      'Nothing was saved.';
  static const String reconfirmLabel = 'Re-confirm pattern';
  static const String startOverLabel = 'Start over';
  static const String clearLabel = 'Clear';
  static const String tooShortMessage = 'Connect at least 4 dots';
  static const String saveFailedMessage =
      'Could not save your pattern. Please try again.';

  /// Fixed grid size so the geometry is predictable (and testable).
  static const double gridSize = 280;

  @override
  State<PatternSetupScreen> createState() => _PatternSetupScreenState();
}

class _PatternSetupScreenState extends State<PatternSetupScreen>
    with SingleTickerProviderStateMixin, EntryShakeMixin {
  PatternSetupStep _step = PatternSetupStep.enter;
  List<int> _nodes = <int>[];
  List<int>? _firstPattern;
  String? _error;
  bool _saving = false;

  /// Pattern trail visibility (Phase 2K/device fix): ALL pattern screens
  /// honor the same persisted preference. Defaults to visible while the
  /// setting loads (accessible fallback when no manager is in scope).
  bool _patternVisible = true;

  @override
  void initState() {
    super.initState();
    initShake();
    _loadVisibility();
  }

  @override
  void dispose() {
    disposeShake();
    super.dispose();
  }

  /// Reads the persisted visibility preference from the SAME credential
  /// manager the rest of the flow uses (never an independent instance).
  Future<void> _loadVisibility() async {
    final CredentialManager? manager =
        widget.credentialManager ?? AppScope.read(context)?.auth;
    if (manager == null) {
      return; // no container in scope (pure widget tests) -> visible default
    }
    final state = (await manager.status()).valueOrNull;
    if (!mounted || state == null) {
      return;
    }
    setState(() => _patternVisible = state.patternVisibilityEnabled);
  }

  CredentialManager get _manager =>
      widget.credentialManager ?? AppScope.read(context)!.auth;

  void _onNodeAdded(List<int> sequence) {
    if (_saving) {
      return;
    }
    setState(() {
      _nodes = sequence;
      _error = null;
    });
  }

  /// Pointer lifted: validate the completed shape.
  void _onDragEnd() {
    if (_saving) {
      return;
    }
    final List<int> drawn = _nodes;

    // Too short: inline error, stay on the same step.
    if (PatternPolicy.defaults.validate(drawn) != PatternValidation.valid) {
      shake();
      setState(() {
        _error = PatternSetupScreen.tooShortMessage;
        _nodes = <int>[];
      });
      return;
    }

    if (_step == PatternSetupStep.enter) {
      setState(() {
        _firstPattern = drawn;
        _step = PatternSetupStep.confirm;
        _nodes = <int>[];
      });
      return;
    }

    // Confirmation: the exact ordered sequence must match.
    if (PatternCodec.matches(_firstPattern!, drawn)) {
      _enroll(drawn);
    } else {
      shake();
      setState(() {
        _step = PatternSetupStep.mismatch;
        _nodes = <int>[];
      });
    }
  }

  void _reconfirm() {
    setState(() {
      _step = PatternSetupStep.confirm;
      _nodes = <int>[];
      _error = null;
    });
  }

  void _startOver() {
    setState(() {
      _step = PatternSetupStep.enter;
      _firstPattern = null;
      _nodes = <int>[];
      _error = null;
    });
  }

  void _clear() {
    if (_saving) {
      return;
    }
    // Clear resets the drawing AND any validation/error state — the
    // screen returns to the pristine first-draw state.
    setState(() {
      _nodes = <int>[];
      _error = null;
    });
  }

  Future<void> _enroll(List<int> nodes) async {
    setState(() => _saving = true);
    final result = await _manager.enrollPattern(nodes);
    if (!mounted) {
      return;
    }
    if (result.isSuccess) {
      setState(() {
        _saving = false;
        _step = PatternSetupStep.success;
        _nodes = <int>[];
        _firstPattern = null;
      });
    } else {
      setState(() {
        _saving = false;
        _error = PatternSetupScreen.saveFailedMessage;
        _step = PatternSetupStep.enter;
        _firstPattern = null;
        _nodes = <int>[];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: switch (_step) {
            PatternSetupStep.enter => _buildEntry(confirming: false),
            PatternSetupStep.confirm => _buildEntry(confirming: true),
            PatternSetupStep.mismatch => _buildMismatch(),
            PatternSetupStep.success => _buildSuccess(),
          },
        ),
      ),
    );
  }

  Widget _buildEntry({required bool confirming}) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: ValueKey<String>(confirming ? 'confirm' : 'enter'),
      padding: DsInsets.screen,
      children: <Widget>[
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            confirming
                ? PatternSetupScreen.confirmTitle
                : PatternSetupScreen.enterTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        Center(
          child: Text(
            confirming
                ? 'Draw the same pattern again'
                : 'Connect at least 4 dots without lifting your finger',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        // Fixed-height error slot: the banner must NEVER shift the grid
        // mid-stroke when it appears or clears between attempts.
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
              width: PatternSetupScreen.gridSize,
              height: PatternSetupScreen.gridSize,
              child: DsPatternGrid(
                nodes: _nodes,
                onNodeAdded: _onNodeAdded,
                onDragEnd: _onDragEnd,
                enabled: !_saving,
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
            label: PatternSetupScreen.clearLabel,
            variant: DsButtonVariant.ghost,
            size: DsButtonSize.small,
            onPressed: _saving ? null : _clear,
          ),
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
      ],
    );
  }

  Widget _buildMismatch() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
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
              border: Border.all(
                color: palette.danger.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(Icons.sync_problem, size: 36, color: palette.danger),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            PatternSetupScreen.mismatchTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            PatternSetupScreen.mismatchMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: shakeWrap(
            SizedBox(
              width: PatternSetupScreen.gridSize,
              height: PatternSetupScreen.gridSize,
              child: const DsPatternGrid(
                nodes: <int>[],
                enabled: false,
                error: true,
              ),
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: PatternSetupScreen.reconfirmLabel,
          expand: true,
          onPressed: _reconfirm,
        ),
        const SizedBox(height: DsSpacing.md),
        DsButton(
          label: PatternSetupScreen.startOverLabel,
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
            PatternSetupScreen.successTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            'Your pattern protects your apps from now on.',
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
