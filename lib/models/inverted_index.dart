// lib/models/inverted_index.dart

class InvertedIndex {
  final Map<String, Set<String>> _index = {};
  int _fileCount = 0; // 记录索引的文件数量

  /// 添加文件到索引（单词去重）
  void addFile(String filePath, List<String> words) {
    // 单词去重（同一个文件中重复的词只记录一次路径）
    final uniqueWords = words.toSet();
    for (final word in uniqueWords) {
      _index.putIfAbsent(word, () => <String>{}).add(filePath);
    }
    _fileCount++;
  }

  /// 搜索：返回每个文件匹配的查询词数量
  Map<String, int> search(List<String> queryWords) {
    final result = <String, int>{};
    // 查询词去重（避免重复计数）
    final uniqueQueryWords = queryWords.toSet();
    for (final word in uniqueQueryWords) {
      final files = _index[word];
      if (files != null) {
        for (final file in files) {
          result[file] = (result[file] ?? 0) + 1;
        }
      }
    }
    return result;
  }

  /// 索引的文件数
  int get fileCount => _fileCount;

  /// 清空索引
  void clear() {
    _index.clear();
    _fileCount = 0;
  }
}
