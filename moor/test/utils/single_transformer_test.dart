import 'dart:async';

import 'package:moor/src/utils/single_transformer.dart';
import 'package:test/test.dart';

void main() {
  test('transforms simple values', () {
    final controller = StreamController<List<int>>();
    final stream = controller.stream.transform(singleElements());

    expectLater(stream, emitsInOrder([1, 2, 3, 4]));

    controller..add([1])..add([2])..add([3])..add([4]);
  });

  test('emits errors for invalid lists', () {
    final controller = StreamController<List<int>>();
    final stream = controller.stream.transform(singleElements());

    expectLater(stream, emitsInOrder([1, emitsError(anything), 2, null]));

    controller..add([1])..add([2, 3])..add([2])..add([]);
  });
}
