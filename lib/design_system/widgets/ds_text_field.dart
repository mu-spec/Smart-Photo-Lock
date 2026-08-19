import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';
import '../ds_radii.dart';

/// Input decoration builder shared by [DsTextField] and the global theme.
abstract final class DsInputDecor {
  /// Complete [InputDecoration] for a single field.
  static InputDecoration build(
    DsPalette palette, {
    String? label,
    String? hint,
    Widget? leadingIcon,
    Widget? trailingIcon,
    String? errorText,
    String? helperText,
    bool filled = true,
  }) {
    final OutlineInputBorder base = OutlineInputBorder(
      borderRadius: BorderRadius.circular(DsRadii.md),
      borderSide: BorderSide(color: palette.border),
    );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: leadingIcon,
      suffixIcon: trailingIcon,
      errorText: errorText,
      helperText: helperText,
      helperMaxLines: 2,
      filled: filled,
      fillColor: palette.surface,
      labelStyle: TextStyle(color: palette.textSecondary),
      hintStyle: TextStyle(color: palette.textSecondary.withValues(alpha: 0.7)),
      helperStyle: TextStyle(color: palette.textSecondary, fontSize: 12),
      errorStyle: TextStyle(color: palette.danger, fontSize: 12),
      prefixIconColor: palette.textSecondary,
      suffixIconColor: palette.textSecondary,
      enabledBorder: base,
      focusedBorder: base.copyWith(
        borderSide: BorderSide(color: palette.primary, width: 1.6),
      ),
      errorBorder: base.copyWith(borderSide: BorderSide(color: palette.danger)),
      focusedErrorBorder: base.copyWith(
        borderSide: BorderSide(color: palette.danger, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  /// Theme-level defaults so even raw `TextField`s match the design system.
  static InputDecorationTheme theme(DsPalette palette) {
    final OutlineInputBorder base = OutlineInputBorder(
      borderRadius: BorderRadius.circular(DsRadii.md),
      borderSide: BorderSide(color: palette.border),
    );
    return InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      labelStyle: TextStyle(color: palette.textSecondary),
      hintStyle: TextStyle(color: palette.textSecondary.withValues(alpha: 0.7)),
      errorStyle: TextStyle(color: palette.danger, fontSize: 12),
      enabledBorder: base,
      focusedBorder: base.copyWith(
        borderSide: BorderSide(color: palette.primary, width: 1.6),
      ),
      errorBorder: base.copyWith(borderSide: BorderSide(color: palette.danger)),
      focusedErrorBorder: base.copyWith(
        borderSide: BorderSide(color: palette.danger, width: 1.6),
      ),
    );
  }
}

/// The app's text field — labels, helper/error text, icons, and a built-in
/// password visibility toggle.
///
/// Drop it inside a [Form] to use [validator]-based errors, or pass
/// [errorText] directly for controlled usage.
class DsTextField extends StatefulWidget {
  const DsTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.leadingIcon,
    this.trailingIcon,
    this.obscureText = false,
    this.errorText,
    this.helperText,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final Widget? leadingIcon;
  final Widget? trailingIcon;

  /// When true, renders as a password field with a visibility toggle.
  final bool obscureText;

  final String? errorText;
  final String? helperText;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int maxLines;
  final TextCapitalization textCapitalization;

  @override
  State<DsTextField> createState() => _DsTextFieldState();
}

class _DsTextFieldState extends State<DsTextField> {
  late bool _obscured = widget.obscureText;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    Widget? trailing = widget.trailingIcon;
    if (widget.obscureText) {
      trailing = IconButton(
        tooltip: _obscured ? 'Show text' : 'Hide text',
        icon: Icon(
          _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
        color: palette.textSecondary,
        onPressed: () => setState(() => _obscured = !_obscured),
      );
    }

    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      maxLines: widget.maxLines,
      textCapitalization: widget.textCapitalization,
      obscureText: widget.obscureText && _obscured,
      validator: widget.validator,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onFieldSubmitted,
      decoration: DsInputDecor.build(
        palette,
        label: widget.label,
        hint: widget.hint,
        leadingIcon: widget.leadingIcon,
        trailingIcon: trailing,
        errorText: widget.errorText,
        helperText: widget.helperText,
      ),
    );
  }
}
