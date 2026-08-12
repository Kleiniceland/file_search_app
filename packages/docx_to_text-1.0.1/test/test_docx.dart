import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    print('用法: dart test_docx.dart <docx文件路径>');
    return;
  }

  final filePath = arguments[0];
  final file = File(filePath);

  if (!file.existsSync()) {
    print('错误: 文件不存在 - $filePath');
    return;
  }

  print('开始测试 DOCX 文件: $filePath');
  final bytes = file.readAsBytesSync();
  print('文件大小: ${bytes.length} 字节');

  final text = extractDocxText(bytes);
  print('=' * 50);
  print('提取的文本内容:');
  print(text.isEmpty ? '(空)' : text);
  print('=' * 50);
  print('文本长度: ${text.length} 字符');
}

/// 从 DOCX 字节数组中提取纯文本
String extractDocxText(List<int> bytes) {
  try {
    // 1. 解压 ZIP
    final archive = ZipDecoder().decodeBytes(bytes);
    print('ZIP 文件数量: ${archive.files.length}');

    // 2. 找到 word/document.xml
    final documentFile = archive.firstWhere(
      (file) => file.name == 'word/document.xml',
      orElse: () => ArchiveFile('', 0, null),
    );

    if (documentFile.content == null || documentFile.content!.isEmpty) {
      print('错误: word/document.xml 不存在或为空');
      return '';
    }

    // 3. 读取 XML 字节并解码
    final xmlBytes = documentFile.content!.toList();
    final xmlString = utf8.decode(xmlBytes);
    print('XML 长度: ${xmlString.length}');

    // 4. 解析 XML
    final document = XmlDocument.parse(xmlString);
    final buffer = StringBuffer();

    // 5. 遍历所有 w:p 段落（使用 findAllElements，忽略命名空间前缀）
    for (final paragraph in document.findAllElements('p')) {
      // 确保是 w:p 段落（DOCX 标准中段落标签就是 w:p）
      final texts = paragraph
          .findAllElements('t') // w:t 文本元素
          .map((node) => node.text)
          .join();
      if (texts.isNotEmpty) {
        buffer.writeln(texts);
      }
    }

    return buffer.toString().trim();
  } catch (e) {
    print('DOCX 解析失败: $e');
    return '';
  }
}
