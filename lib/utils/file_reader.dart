import 'dart:typed_data';

/// 文件读取器抽象接口
///
/// 所有格式（PDF / PNG / JPG / DOCX / ...）的 Reader 都实现此接口，
/// 由 [FileReaderFactory] 统一分发，避免暴露多个独立函数入口。
abstract class FileReader {
  /// 从文件字节中读取（提取）文本内容
  ///
  /// 返回空字符串表示无文本可提取或读取失败。
  Future<String> read(Uint8List bytes);
}
