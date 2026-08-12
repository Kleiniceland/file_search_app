import 'dart:math' as math;

import 'embedding_engine.dart';
import 'vector_store.dart';

/// 混合搜索结果项
class HybridSearchResult {
  final String filePath;
  final String fileName;
  final String fileType;
  final String contentSnippet;
  final double vectorScore; // 语义相似度 (0~1)
  final double keywordScore; // 关键词匹配度 (0~1)
  final double finalScore; // 融合后的最终得分
  final int fileSize;

  HybridSearchResult({
    required this.filePath,
    required this.fileName,
    required this.fileType,
    required this.contentSnippet,
    required this.vectorScore,
    required this.keywordScore,
    required this.finalScore,
    required this.fileSize,
  });
}

/// 混合语义检索服务
///
/// 融合两条检索路径：
/// 1. 向量语义搜索（BERT 嵌入 + 余弦相似度）
/// 2. 关键词匹配（文件名 + 内容子串匹配）
///
/// 融合策略：finalScore = α * vectorScore + (1-α) * keywordScore
class SearchService {
  final EmbeddingEngine _engine;
  final VectorStore _vectorStore;

  /// 向量搜索权重（0~1），默认 0.7 偏向语义搜索
  final double vectorWeight;

  SearchService({
    required EmbeddingEngine engine,
    required VectorStore vectorStore,
    this.vectorWeight = 0.7,
  })  : _engine = engine,
        _vectorStore = vectorStore;

  /// 执行混合搜索
  ///
  /// [query] 搜索查询文本
  /// [topK] 返回前 K 个结果
  /// [filterType] 可选，按文件类型过滤 ('text' | 'image')
  Future<List<HybridSearchResult>> search(
    String query, {
    int topK = 10,
    String? filterType,
  }) async {
    if (query.trim().isEmpty) return [];

    final queryLower = query.toLowerCase();
    final queryTokens = _tokenize(queryLower);

    // ===== 跨模态搜索：文本文件用 BERT，图片文件用 MobileCLIP 文本编码器 =====

    // 1. BERT 向量搜索文本文件
    final bertVector = await _engine.embedText(query);
    final textResults = _vectorStore.search(
      bertVector,
      topK: topK * 3,
      filterType: filterType ?? 'text',
    );

    // 2. MobileCLIP 文本向量搜索图片文件（如果可用）
    List<VectorSearchResult> imageResults = [];
    try {
      final clipVector = await _engine.embedTextForImage(query);
      imageResults = _vectorStore.search(
        clipVector,
        topK: topK * 3,
        filterType: filterType ?? 'image',
      );
    } catch (_) {
      // MobileCLIP 文本编码器未加载，用文件名匹配搜索图片
      imageResults = _searchImagesByFilename(queryLower, queryTokens, topK * 3);
    }

    // 合并搜索结果
    final allResults = [...textResults, ...imageResults];

    // 3. 关键词匹配 + 融合得分
    final results = <HybridSearchResult>[];

    for (final vr in allResults) {
      final record = vr.record;

      // 关键词得分
      final kwScore = _keywordScore(
        queryLower,
        queryTokens,
        record.fileName,
        record.content,
      );

      // 融合得分
      double finalScore;
      if (record.fileType == 'image') {
        // 图片文件：语义得分（MobileCLIP）更可靠，权重更高
        finalScore = 0.7 * vr.similarity + 0.3 * kwScore;
      } else if (kwScore > 0) {
        // 文本文件有关键词匹配：关键词优先
        finalScore = 0.4 * vr.similarity + 0.6 * kwScore;
      } else {
        // 文本文件无关键词匹配：语义得分折扣
        finalScore = 0.3 * vr.similarity;
      }

      results.add(HybridSearchResult(
        filePath: record.filePath,
        fileName: record.fileName,
        fileType: record.fileType,
        contentSnippet: _extractSnippet(record.content, query),
        vectorScore: vr.similarity,
        keywordScore: kwScore,
        finalScore: finalScore,
        fileSize: record.fileSize,
      ));
    }

    // 4. 按融合得分排序
    results.sort((a, b) => b.finalScore.compareTo(a.finalScore));

    // 5. 按 filePath 去重（保留得分最高的）
    final seen = <String>{};
    final deduped = results.where((r) {
      if (seen.contains(r.filePath)) return false;
      seen.add(r.filePath);
      return true;
    }).toList();

    // 6. 过滤掉得分过低的结果
    // 图片文件的 CLIP 跨模态相似度绝对值通常较低（0.05~0.20），
    // 使用更低的阈值，避免图片结果被误过滤
    final filtered = deduped.where((r) {
      if (r.fileType == 'image') {
        return r.finalScore >= 0.03;
      }
      return r.finalScore >= 0.15;
    }).toList();

    // 7. 截断到 topK
    if (filtered.length > topK) {
      return filtered.sublist(0, topK);
    }
    return filtered;
  }

  /// 仅向量搜索（不做关键词融合）
  Future<List<HybridSearchResult>> vectorSearch(
    String query, {
    int topK = 10,
    String? filterType,
  }) async {
    if (query.trim().isEmpty) return [];

    final queryVector = await _engine.embedText(query);
    final vectorResults = _vectorStore.search(
      queryVector,
      topK: topK,
      filterType: filterType,
    );

    return vectorResults.map((vr) {
      final record = vr.record;
      return HybridSearchResult(
        filePath: record.filePath,
        fileName: record.fileName,
        fileType: record.fileType,
        contentSnippet: _extractSnippet(record.content, query),
        vectorScore: vr.similarity,
        keywordScore: 0,
        finalScore: vr.similarity,
        fileSize: record.fileSize,
      );
    }).toList();
  }

  /// 用文件名匹配搜索图片文件（MobileCLIP 文本编码器未加载时的回退方案）
  ///
  /// 返回文件名匹配查询词的图片记录，similarity 为匹配度（0~1）
  List<VectorSearchResult> _searchImagesByFilename(
    String queryLower,
    List<String> queryTokens,
    int topK,
  ) {
    final results = <VectorSearchResult>[];

    for (final record in _vectorStore.allRecords) {
      if (record.fileType != 'image') continue;

      final fileNameLower = record.fileName.toLowerCase();
      double sim = 0.0;

      // 文件名精确子串匹配
      if (fileNameLower.contains(queryLower)) {
        sim = 0.9;
      } else if (queryTokens.isNotEmpty) {
        // token 匹配
        int matched = 0;
        for (final qt in queryTokens) {
          if (fileNameLower.contains(qt)) matched++;
        }
        sim = matched / queryTokens.length * 0.7;
      }

      if (sim > 0) {
        results.add(VectorSearchResult(record: record, similarity: sim));
      }
    }

    results.sort((a, b) => b.similarity.compareTo(a.similarity));
    if (results.length > topK) {
      return results.sublist(0, topK);
    }
    return results;
  }

  /// 关键词得分计算（0~1）
  ///
  /// 综合文件名匹配和内容匹配
  double _keywordScore(
    String queryLower,
    List<String> queryTokens,
    String fileName,
    String content,
  ) {
    double score = 0.0;

    // 文件名精确子串匹配
    final fileNameLower = fileName.toLowerCase();
    if (fileNameLower.contains(queryLower)) {
      score = math.max(score, 1.0);
    }

    // 文件名 token 匹配
    if (queryTokens.isNotEmpty) {
      final fileNameTokens = _tokenize(fileNameLower);
      int matched = 0;
      for (final qt in queryTokens) {
        if (fileNameTokens.any((ft) => ft.contains(qt))) {
          matched++;
        }
      }
      score = math.max(score, matched / queryTokens.length * 0.8);
    }

    // 内容子串匹配
    final contentLower = content.toLowerCase();
    if (contentLower.contains(queryLower)) {
      score = math.max(score, 0.9);
    }

    // 内容 token 覆盖率
    if (queryTokens.isNotEmpty) {
      int matched = 0;
      for (final qt in queryTokens) {
        if (contentLower.contains(qt)) {
          matched++;
        }
      }
      score = math.max(score, matched / queryTokens.length * 0.6);
    }

    return score;
  }

  /// 分词：英文按单词，中文按单字
  ///
  /// Dart 的 \w 不匹配中文字符，需要单独处理。
  /// 中文逐字拆分后做单字匹配，保证 "猫咪怎么养" 能匹配到 "猫咪饲养"。
  List<String> _tokenize(String text) {
    final tokens = <String>[];
    final regex = RegExp(r'[a-zA-Z0-9_]+|[\u4e00-\u9fff]');
    for (final match in regex.allMatches(text)) {
      final s = match.group(0)!;
      if (s.length > 1) {
        // 英文/数字 token（长度 > 1）
        tokens.add(s.toLowerCase());
      } else if (RegExp(r'[\u4e00-\u9fff]').hasMatch(s)) {
        // 中文字符逐字拆分
        tokens.add(s);
      }
    }
    return tokens;
  }

  /// 提取查询词周围的内容片段
  String _extractSnippet(String content, String query, {int contextLen = 80}) {
    if (content.isEmpty) return '';

    final idx = content.toLowerCase().indexOf(query.toLowerCase());
    if (idx == -1) {
      // 没找到精确匹配，返回前 100 字符
      return content.length > 100 ? '${content.substring(0, 100)}...' : content;
    }

    final start = (idx - contextLen).clamp(0, content.length);
    final end = (idx + query.length + contextLen).clamp(0, content.length);
    final prefix = start > 0 ? '...' : '';
    final suffix = end < content.length ? '...' : '';
    return '$prefix${content.substring(start, end)}$suffix';
  }
}
