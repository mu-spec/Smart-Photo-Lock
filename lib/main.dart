import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/app_container.dart';

/// Smart App Lock — application entry point.
///
/// Boots the persistence layer (Phase 1E: shared_preferences + SQLite)
/// before the first frame, then hands the container to the widget tree so
/// later phases can resolve repositories anywhere.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final AppContainer container = await AppContainer.create();
  runApp(SmartAppLockApp(container: container));
}
