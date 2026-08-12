import 'dart:io';
import 'dart:collection';
import '../utils/file_utils.dart';

/// 简单的倒排索引服务
class IndexService {
  // 倒排索引：词 → {文件路径 → 出现次数}
  final HashMap<String, HashMap<String, int>> _invertedIndex = HashMap();

  /// 扫描目录并构建索引
  void buildIndex(String rootPath) {
    final dir = Directory(rootPath);
    if (!dir.existsSync()) return;

    final files = dir.listSync(recursive: true).whereType<File>();
    for (final file in files) {
      if (isSupportedFile(file)) {
        _indexFile(file);
      }
    }
  }

  /// 索引单个文件
  void _indexFile(File file) {
    // 1. 从文件路径提取关键词（目录名 + 文件名）
    final tokens = _tokenizePath(file.path);
    for (final token in tokens) {
      _addToIndex(token, file.path);
    }

    // 2. 对于文本文件（txt / docx），额外索引内容
    final ext = file.path.split('.').last.toLowerCase();
    if (ext == 'txt' || ext == 'doc' || ext == 'docx') {
      try {
        final content = file.readAsStringSync(); // 简单读取txt；word需额外库
        final contentTokens = _simpleSegment(content);
        for (final token in contentTokens) {
          _addToIndex(token, file.path);
        }
      } catch (e) {
        // 如果读取失败（如二进制文件），忽略
      }
    }
  }

  /// 简易分词：按空格、标点符号、中文单字分割（用于文件名和内容）
  List<String> _tokenizePath(String path) {
    // 提取文件名（不含扩展名）
    final fileName = path.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
    // 按非单词字符分割
    final parts = fileName.split(RegExp(r'[_\-\s.]+'));
    return parts.where((s) => s.isNotEmpty).toList();
  }

  /// 简易中文分词（按字符分割，适合短文本）
  List<String> _simpleSegment(String text) {
    final result = <String>[];
    final buffer = StringBuffer();
    for (final char in text.runes) {
      final c = String.fromCharCode(char);
      if (RegExp(r'[\u4e00-\u9fff]').hasMatch(c)) {
        // 中文字符作为单独词
        if (buffer.isNotEmpty) {
          result.add(buffer.toString().toLowerCase());
          buffer.clear();
        }
        result.add(c);
      } else if (RegExp(r'[a-zA-Z0-9]').hasMatch(c)) {
        buffer.write(c);
      } else if (RegExp(r'\s').hasMatch(c)) {
        // 空白分隔
        if (buffer.isNotEmpty) {
          result.add(buffer.toString().toLowerCase());
          buffer.clear();
        }
      } else {
        // 其他符号忽略
        if (buffer.isNotEmpty) {
          result.add(buffer.toString().toLowerCase());
          buffer.clear();
        }
      }
    }
    if (buffer.isNotEmpty) {
      result.add(buffer.toString().toLowerCase());
    }
    return result;
  }

  void _addToIndex(String word, String filePath) {
    _invertedIndex.putIfAbsent(word, () => HashMap());
    final fileCounts = _invertedIndex[word]!;
    fileCounts[filePath] = (fileCounts[filePath] ?? 0) + 1;
  }

  /// 搜索：返回匹配的文件路径列表（按出现次数排序）
  List<String> search(String query) {
    if (query.isEmpty) return [];
    // 对查询进行分词
    final queryTokens = _simpleSegment(query);
    if (queryTokens.isEmpty) return [];

    // 收集所有包含任一 token 的文件，并统计匹配度
    final fileScores = HashMap<String, int>();
    for (final token in queryTokens) {
      final tokenLower = token.toLowerCase();
      if (_invertedIndex.containsKey(tokenLower)) {
        for (final entry in _invertedIndex[tokenLower]!.entries) {
          fileScores[entry.key] = (fileScores[entry.key] ?? 0) + entry.value;
        }
      }
    }

    // 按匹配度降序排序
    final sortedEntries = fileScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sortedEntries.map((e) => e.key).toList();
  }

  Future<void> buildIndexAsync(String searchDirectory) async {}
}//新的