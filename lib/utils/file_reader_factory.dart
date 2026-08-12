import 'file_reader.dart';
import 'pdf_reader.dart';
import 'png_reader.dart';
import 'jpg_reader.dart';
import 'docx_reader.dart';

/// 文件读取器工厂
///
/// 统一入口：根据文件路径返回对应的 [FileReader]。
/// 调用方只需：
/// ```dart
/// final reader = FileReaderFactory.getReader(file.path);
/// if (reader != null) {
///   final text = await reader.read(bytes);
/// }
/// ```
/// 避免暴露多个独立的 extract* 函数入口。
class FileReaderFactory {
  FileReaderFactory._(); // 禁止实例化

  /// 根据文件路径获取对应的读取器，不支持的格式返回 null
  static FileReader? getReader(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.pdf')) return PdfReader();
    if (lower.endsWith('.png')) return PngReader();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return JpgReader();
    if (lower.endsWith('.docx')) return DocxReader();
    return null;
  }
}
