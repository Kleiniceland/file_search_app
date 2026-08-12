import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'file_reader.dart';

/// PDF 文件读取器
///
/// 使用 syncfusion_flutter_pdf 提取文本层。
/// 扫描版 PDF（无文本层）会返回空字符串 —— OCR 兜底暂未实现。
class PdfReader implements FileReader {
  @override
  Future<String> read(Uint8List bytes) async {
    // 用 compute 丢到 isolate 跑，避免大 PDF 阻塞 UI 线程。
    // syncfusion_flutter_pdf 是纯 Dart 库，无平台通道，isolate 安全。
    return compute(extractPdfText, bytes);
  }
}

/// 顶层函数，供 compute 调用。错误时返回空字符串。
String extractPdfText(Uint8List bytes) {
  try {
    final doc = PdfDocument(inputBytes: bytes);
    final text = PdfTextExtractor(doc).extractText();
    doc.dispose();
    return text;
  } catch (_) {
    return '';
  }
}
