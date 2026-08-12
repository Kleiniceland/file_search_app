import 'dart:convert';
import 'dart:io';

class FileService {
  Future<String> readFileWithFallback(File file) async {
    const encodings = ['utf8', 'gbk', 'gb2312', 'latin1'];
    for (final name in encodings) {
      try {
        final encoding = Encoding.getByName(name)!;
        return await file.readAsString(encoding: encoding);
      } catch (_) {
        continue;
      }
    }
    throw FormatException('无法读取文件: ${file.path}');
  }
}
