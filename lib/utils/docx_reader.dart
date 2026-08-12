import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'file_reader.dart';

/// DOCX 文件读取器
///
/// 复用原 extractDocxText 逻辑：解压 docx → 解析 word/document.xml → 抽 <w:t>。
class DocxReader implements FileReader {
  @override
  Future<String> read(Uint8List bytes) async {
    // 用 compute 丢到 isolate 跑，避免大 docx 阻塞 UI 线程。
    // archive / xml 均为纯 Dart 库，isolate 安全。
    return compute(extractDocxText, bytes);
  }
}

/// 顶层函数，供 compute 调用。错误时返回空字符串。
String extractDocxText(Uint8List bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentFile = archive.files.firstWhere(
      (f) => f.name == 'word/document.xml',
      orElse: () => throw Exception('未找到 document.xml'),
    );
    final xmlContent = utf8.decode(documentFile.content as List<int>);
    final regex = RegExp(r'<w:t[^>]*>([^<]*)</w:t>');
    final matches = regex.allMatches(xmlContent);
    return matches.map((m) => m.group(1)!).join('').trim();
  } catch (_) {
    return '';
  }
}
