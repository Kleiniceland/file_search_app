import 'package:flutter_test/flutter_test.dart';
import 'package:file_search_app/utils/file_reader_factory.dart';
import 'package:file_search_app/utils/pdf_reader.dart';
import 'package:file_search_app/utils/docx_reader.dart';
import 'package:file_search_app/utils/png_reader.dart';
import 'package:file_search_app/utils/jpg_reader.dart';

void main() {
  group('FileReaderFactory', () {
    test('getReader returns PdfReader for .pdf', () {
      final reader = FileReaderFactory.getReader('test.pdf');
      expect(reader, isA<PdfReader>());
    });

    test('getReader returns PdfReader for .PDF (uppercase)', () {
      final reader = FileReaderFactory.getReader('test.PDF');
      expect(reader, isA<PdfReader>());
    });

    test('getReader returns DocxReader for .docx', () {
      final reader = FileReaderFactory.getReader('test.docx');
      expect(reader, isA<DocxReader>());
    });

    test('getReader returns PngReader for .png', () {
      final reader = FileReaderFactory.getReader('test.png');
      expect(reader, isA<PngReader>());
    });

    test('getReader returns JpgReader for .jpg', () {
      final reader = FileReaderFactory.getReader('test.jpg');
      expect(reader, isA<JpgReader>());
    });

    test('getReader returns JpgReader for .jpeg', () {
      final reader = FileReaderFactory.getReader('test.jpeg');
      expect(reader, isA<JpgReader>());
    });

    test('getReader returns null for unsupported format', () {
      final reader = FileReaderFactory.getReader('test.xyz');
      expect(reader, isNull);
    });
    
    test('getReader returns null for .txt', () {
      final reader = FileReaderFactory.getReader('test.txt');
      expect(reader, isNull);
    });
  });
}
