import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:file_search_app/utils/png_reader.dart';
import 'package:file_search_app/utils/jpg_reader.dart';

void main() {
  group('PngReader', () {
    test('read returns empty string (stub)', () async {
      final reader = PngReader();
      final result = await reader.read(Uint8List.fromList([1, 2, 3]));
      expect(result, isEmpty);
    });
  });

  group('JpgReader', () {
    test('read returns empty string (stub)', () async {
      final reader = JpgReader();
      final result = await reader.read(Uint8List.fromList([1, 2, 3]));
      expect(result, isEmpty);
    });
  });
}
