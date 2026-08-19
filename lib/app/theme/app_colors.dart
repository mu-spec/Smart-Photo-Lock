import 'package:flutter/material.dart';

/// Brand palette for Smart App Lock (dark-first design).
///
/// Deep navy surfaces with a teal accent. Semantic helpers below map to
/// lock semantics: green = allowed/unlocked, red = blocked/locked.
abstract final class AppColors {
  // Brand surfaces
  static const Color navy900 = Color(0xFF0F1630); // scaffold background
  static const Color navy800 = Color(0xFF101A3C); // brand navy
  static const Color navy700 = Color(0xFF1A2550); // cards
  static const Color navy600 = Color(0xFF24336B); // elevated surfaces

  // Accent
  static const Color accent = Color(0xFF2DD4BF); // teal
  static const Color accentDim = Color(0xFF14B8A6);

  // Text
  static const Color textPrimary = Color(0xFFE8ECF8);
  static const Color textSecondary = Color(0xFF9AA5C7);

  // Semantics
  static const Color success = Color(0xFF34D399);
  static const Color danger = Color(0xFFF87171);
  static const Color warning = Color(0xFFFBBF24);
}
