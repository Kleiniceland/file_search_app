import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_search_app/utils/docx_reader.dart';

void main() {
  group('extractDocxText', () {
    test('returns empty string for empty bytes', () {
      final result = extractDocxText(Uint8List(0));
      expect(result, isEmpty);
    });

    test('returns empty string for invalid bytes', () {
      final result = extractDocxText(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(result, isEmpty);
    });

    test('extracts text from valid docx bytes', () {
      // 构造一个内存中的 DOCX (ZIP with word/document.xml)
      final xmlContent = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          '<w:body><w:p><w:r><w:t>Hello World</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>Test Content</w:t></w:r></w:p>'
          '</w:body></w:document>';

      final archive = Archive()
        ..addFile(ArchiveFile(
          'word/document.xml',
          xmlContent.length,
          utf8.encode(xmlContent),
        ));

      final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
      final result = extractDocxText(bytes);

      expect(result, contains('Hello World'));
      expect(result, contains('Test Content'));
    });

    test('returns empty string if document.xml is missing', () {
      // 一个有效的 ZIP，但没有 word/document.xml
      final archive = Archive()
        ..addFile(ArchiveFile(
          'other/file.txt',
          4,
          utf8.encode('test'),
        ));

      final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
      final result = extractDocxText(bytes);

      expect(result, isEmpty);
    });
  });
}
