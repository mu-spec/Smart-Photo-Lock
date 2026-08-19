import 'dart:math' as math;

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
///
/// [digitOrder] controls where digits appear: the first 9 entries fill the
/// grid (row-major) and the 10th sits at the bottom-center. The default is
/// the familiar 1-9 layout (understandable & accessible); pass a shuffled
/// order (see [shuffledDigitOrder]) to randomize the keypad.
class DsPinPad extends StatelessWidget {
  const DsPinPad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.onDeleteAll,
    this.onBiometric,
    this.showBiometric = false,
    this.enabled = true,
    this.digitOrder = defaultDigitOrder,
  });

  /// The standard, accessible 1-9 layout (with 0 bottom-center).
  static const List<String> defaultDigitOrder = <String>[
    '1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
  ];

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

  /// Position order of the ten digits (length 10, must contain each digit
  /// 0-9 exactly once). Keys keep their identity by value —
  /// `Key('pin_key_5')` always refers to digit '5' wherever it is rendered.
  final List<String> digitOrder;

  @override
  Widget build(BuildContext context) {
    final List<String> grid = digitOrder.sublist(0, 9);
    final String bottomCenter = digitOrder[9];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int row = 0; row < 3; row++)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              for (int col = 0; col < 3; col++)
                _PinKey(
                  key: Key('pin_key_${grid[row * 3 + col]}'),
                  label: grid[row * 3 + col],
                  onTap: enabled
                      ? () => onDigit(grid[row * 3 + col])
                      : null,
                ),
            ],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            if (showBiometric)
              _PinKey(
                key: const Key('pin_key_biometric'),
                label: '',
                icon: Icons.fingerprint,
                onTap: (enabled && onBiometric != null) ? onBiometric : null,
              )
            else
              // Inert layout spacer for keypad symmetry. Deliberately has
              // NO biometric key/icon — it must not masquerade as an
              // actionable biometric control when biometrics are off.
              const _PinKey(label: ''),
            _PinKey(
              key: Key('pin_key_$bottomCenter'),
              label: bottomCenter,
              onTap: enabled ? () => onDigit(bottomCenter) : null,
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

/// Fisher-Yates shuffle of the standard digit order.
///
/// [random] is injectable so tests can replay a deterministic sequence.
List<String> shuffledDigitOrder([math.Random? random]) {
  final math.Random rng = random ?? math.Random();
  final List<String> order = List<String>.from(DsPinPad.defaultDigitOrder);
  for (int i = order.length - 1; i > 0; i--) {
    final int j = rng.nextInt(i + 1);
    final String tmp = order[i];
    order[i] = order[j];
    order[j] = tmp;
  }
  return order;
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
            : label.isEmpty
                ? const SizedBox.shrink()
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
