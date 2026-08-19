import 'package:flutter/widgets.dart';

import 'app_container.dart';

/// Makes the [AppContainer] available to every screen below [SmartAppLockApp].
///
/// Screens resolve dependencies like `AppScope.read(context)!.auth` —
/// keeping the widget tree independent of constructor drilling while widget
/// tests can still inject their own container (or an in-memory one).
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.container,
    required super.child,
  });

  /// The application dependency container (persistence + security wiring).
  final AppContainer container;

  /// The container in scope, or null when absent (pure widget tests).
  ///
  /// Registers a dependency — use inside `build`.
  static AppContainer? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.container;

  /// The container in scope, or null — does NOT register a dependency.
  ///
  /// Safe to use in event handlers and async callbacks.
  static AppContainer? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()?.container;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      container != oldWidget.container;
}
