import 'dart:io';

/// 支持的文件扩展名（小写）
const Set<String> supportedExtensions = {
  'txt',
  'pdf',
  'png',
  'jpg',
  'jpeg',
  'doc',
  'docx',
};

/// 检查文件是否属于支持的类型
bool isSupportedFile(File file) {
  final ext = file.path.split('.').last.toLowerCase();
  return supportedExtensions.contains(ext);
}

/// 文件大小枚举
enum FileSizeRange {
  all('全部', 0, double.infinity),
  small('小文件 (<100KB)', 0, 100 * 1024),
  medium('中等 (100KB ~ 1MB)', 100 * 1024, 1024 * 1024),
  large('大文件 (>1MB)', 1024 * 1024, double.infinity);

  final String label;
  final double minBytes;
  final double maxBytes;

  const FileSizeRange(this.label, this.minBytes, this.maxBytes);

  /// 检查文件路径是否在此区间
  bool matches(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final size = file.lengthSync().toDouble();
    return size >= minBytes && size < maxBytes;
  }
}//xingde