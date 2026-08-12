import 'dart:typed_data';

import 'file_reader.dart';

/// PNG 文件读取器
///
/// 暂未实现：PNG 无文本层，需 OCR；OCR 暂不做。
class PngReader implements FileReader {
  @override
  Future<String> read(Uint8List bytes) async {
    return '';
  }
}
