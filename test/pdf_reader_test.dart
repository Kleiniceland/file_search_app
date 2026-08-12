import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:file_search_app/utils/pdf_reader.dart';

// 构造一个最小的 PDF 字节流，用于测试
// 这个 PDF 包含一行文本 "Hello World"
Uint8List _createMinimalPdfBytes() {
  final content = '''
%PDF-1.0
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/MediaBox[0 0 3 3]/Parent 2 0 R/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 44>>stream
BT /F1 12 Tf 100 700 Td (Hello World) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000111 00000 n 
0000000262 00000 n 
0000000346 00000 n 
trailer<</Size 6/Root 1 0 R>>
startxref
407
%%EOF''';
  return Uint8List.fromList(content.codeUnits);
}

void main() {
  group('extractPdfText', () {
    test('returns empty string for empty bytes', () {
      final result = extractPdfText(Uint8List(0));
      expect(result, isEmpty);
    });

    test('returns empty string for invalid bytes', () {
      final result = extractPdfText(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(result, isEmpty);
    });

    test('extracts text from valid pdf bytes', () {
      final bytes = _createMinimalPdfBytes();
      final result = extractPdfText(bytes);
      // syncfusion_flutter_pdf 应该能提取出 "Hello World"
      expect(result, contains('Hello World'));
    });
  });
}
