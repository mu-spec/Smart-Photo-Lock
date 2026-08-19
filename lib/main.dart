import 'package:flutter/material.dart';

import 'app/app.dart';

/// Smart App Lock — application entry point.
///
/// Phase 1B: wires up the core project architecture (app shell, router,
/// theme, feature modules). No locking behaviour is implemented yet —
/// enforcement arrives in the later protection/service phases.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartAppLockApp());
}
