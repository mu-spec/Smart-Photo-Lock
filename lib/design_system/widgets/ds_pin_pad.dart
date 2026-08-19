import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';

/// Numeric keypad used by every PIN flow (setup, change, unlock).
///
/// Layout:
/// ```
/// 1 2 3
/// 4 5 6
/// 7 8 9
/// [bio] 0 ⌫
/// ```
/// The bottom-left slot renders a biometric shortcut when
/// [showBiometric] is true, otherwise it stays empty.
class DsPinPad extends StatelessWidget {
  const DsPinPad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.onDeleteAll,
    this.onBiometric,
    this.showBiometric = false,
    this.enabled = true,
  });

  /// Fired with '0'..'9'.
  final ValueChanged<String> onDigit;

  /// Backspace pressed.
  final VoidCallback onDelete;

  /// Long-press on backspace (clear the whole entry).
  final VoidCallback? onDeleteAll;

  /// Biometric shortcut pressed (only shown with [showBiometric]).
  final VoidCallback? onBiometric;

  final bool showBiometric;

  /// When false, all keys are inert.
  final bool enabled;

  static const List<List<String>> _rows = <List<String>>[
    <String>['1', '2', '3'],
    <String>['4', '5', '6'],
    <String>['7', '8', '9'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final List<String> row in _rows)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              for (final String digit in row)
                _PinKey(
                  key: Key('pin_key_$digit'),
                  label: digit,
                  onTap: enabled ? () => onDigit(digit) : null,
                ),
            ],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            _PinKey(
              key: const Key('pin_key_biometric'),
              label: '',
              icon: showBiometric ? Icons.fingerprint : null,
              onTap: (showBiometric && enabled && onBiometric != null)
                  ? onBiometric
                  : null,
            ),
            _PinKey(
              key: const Key('pin_key_0'),
              label: '0',
              onTap: enabled ? () => onDigit('0') : null,
            ),
            _PinKey(
              key: const Key('pin_key_backspace'),
              label: '',
              icon: Icons.backspace_outlined,
              onTap: enabled ? onDelete : null,
              onLongPress: (enabled && onDeleteAll != null) ? onDeleteAll : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// A single circular key with ripple feedback.
class _PinKey extends StatelessWidget {
  const _PinKey({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.onLongPress,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final bool inert = onTap == null && onLongPress == null;

    return SizedBox(
      width: 84,
      height: 72,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Center(
            child: icon != null
                ? Icon(
                    icon,
                    size: 24,
                    color: inert
                        ? palette.textSecondary.withValues(alpha: 0.4)
                        : palette.textPrimary,
                  )
                : Text(
                    label,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: inert
                          ? palette.textSecondary.withValues(alpha: 0.4)
                          : palette.textPrimary,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
