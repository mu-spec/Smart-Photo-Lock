/// Lightweight result type used at every Dart/native boundary.
///
/// Repositories and services return `Result<T>` instead of throwing, so
/// callers are forced to handle failure paths explicitly (a failed overlay
/// permission request is an expected state in an app locker, not an error).
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;

  bool get isFailure => this is Failure<T>;

  /// The wrapped value, or null when this is a failure.
  T? get valueOrNull => switch (this) {
        final Success<T> s => s.value,
        _ => null,
      };

  /// The wrapped error, or null when this is a success.
  Object? get errorOrNull => switch (this) {
        final Failure<T> f => f.error,
        _ => null,
      };

  /// Collapses both cases into a single value.
  R fold<R>(R Function(T value) onSuccess, R Function(Object error) onFailure) =>
      switch (this) {
        final Success<T> s => onSuccess(s.value),
        final Failure<T> f => onFailure(f.error),
      };

  factory Result.success(T value) => Success<T>(value);

  factory Result.failure(Object error, [StackTrace? stackTrace]) =>
      Failure<T>(error, stackTrace);
}

/// Successful outcome carrying [value].
final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;
}

/// Failed outcome carrying [error] (and optionally a [stackTrace]).
final class Failure<T> extends Result<T> {
  const Failure(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;
}
