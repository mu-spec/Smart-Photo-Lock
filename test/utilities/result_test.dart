import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/utilities/result.dart';

void main() {
  test('Success carries a value', () {
    const Result<int> r = Success<int>(42);
    expect(r.isSuccess, isTrue);
    expect(r.isFailure, isFalse);
    expect(r.valueOrNull, 42);
    expect(r.errorOrNull, isNull);
    expect(r.fold((int v) => v * 2, (Object e) => 0), 84);
  });

  test('Failure carries an error', () {
    const Result<int> r = Failure<int>('boom');
    expect(r.isFailure, isTrue);
    expect(r.isSuccess, isFalse);
    expect(r.valueOrNull, isNull);
    expect(r.errorOrNull, 'boom');
    expect(r.fold((int v) => v, (Object e) => e), 'boom');
  });

  test('factory constructors infer the right type', () {
    final Result<String> ok = Result<String>.success('done');
    final Result<String> bad = Result<String>.failure(StateError('nope'));
    expect(ok.valueOrNull, 'done');
    expect(bad.errorOrNull, isA<StateError>());
  });
}
