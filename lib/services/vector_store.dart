import 'dart:io';

import 'package:file_search_app/objectbox.g.dart';
import 'package:file_search_app/services/objectbox_model.dart';

/// 向量记录：一个文件对应一条记录
class VectorRecord {
  final String filePath;
  final String fileName;
  final String fileType; // 'text' | 'image'
  final String content; // 提取的文本内容（截断前 500 字符用于摘要）
  final List<double> embedding;
  final DateTime indexedAt;
  final int fileSize;

  VectorRecord({
    required this.filePath,
    required this.fileName,
    required this.fileType,
    required this.content,
    required this.embedding,
    required this.indexedAt,
    required this.fileSize,
  });

  Map<String, dynamic> toMap() => {
        'filePath': filePath,
        'fileName': fileName,
        'fileType': fileType,
        'content': content,
        'embedding': embedding,
        'indexedAt': indexedAt.toIso8601String(),
        'fileSize': fileSize,
      };
}

/// 向量搜索结果
class VectorSearchResult {
  final VectorRecord record;
  final double similarity;

  VectorSearchResult({required this.record, required this.similarity});
}

/// 基于 ObjectBox HNSW 索引的本地向量存储
///
/// 使用 HNSW（分层可导航小世界图）实现 O(log n) 近似最近邻搜索，
/// 替代暴力扫描的 O(n) 余弦相似度计算。完全离线，进程内运行。
class VectorStore {
  Store? _store;
  Box<VectorEntity>? _box;
  bool _initialized = false;

  /// 初始化（打开 ObjectBox Store）
  Future<void> init({String? storagePath}) async {
    if (_initialized) return;

    final dir = storagePath ?? '${Directory.current.path}/.objectbox';
    await Directory(dir).create(recursive: true);
    _store = Store(getObjectBoxModel(), directory: dir);
    _box = _store!.box<VectorEntity>();
    _initialized = true;
  }

  /// VectorRecord → VectorEntity
  VectorEntity _toEntity(VectorRecord record, {int id = 0}) {
    final entity = VectorEntity.fromRecord(
      filePath: record.filePath,
      fileName: record.fileName,
      fileType: record.fileType,
      content: record.content,
      embedding: record.embedding,
      indexedAt: record.indexedAt.millisecondsSinceEpoch,
      fileSize: record.fileSize,
    );
    entity.id = id;
    return entity;
  }

  /// VectorEntity → VectorRecord
  VectorRecord _toRecord(VectorEntity e) {
    return VectorRecord(
      filePath: e.filePath!,
      fileName: e.fileName!,
      fileType: e.fileType!,
      content: e.content!,
      embedding: e.vector!,
      indexedAt: DateTime.fromMillisecondsSinceEpoch(e.indexedAt!),
      fileSize: e.fileSize!,
    );
  }

  /// 添加或更新一条记录
  Future<void> upsert(VectorRecord record) async {
    // 查询是否已存在（按 filePath 唯一索引）
    final existingQuery =
        _box!.query(VectorEntity_.filePath.equals(record.filePath)).build();
    final existing = existingQuery.findFirst();
    existingQuery.close();
    final entity = _toEntity(record, id: existing?.id ?? 0);
    _box!.put(entity);
  }

  /// 批量添加
  Future<void> upsertBatch(List<VectorRecord> records) async {
    for (final record in records) {
      await upsert(record);
    }
  }

  /// 删除一条记录
  Future<void> remove(String filePath) async {
    final query = _box!.query(VectorEntity_.filePath.equals(filePath)).build();
    final entity = query.findFirst();
    query.close();
    if (entity != null) {
      _box!.remove(entity.id);
    }
  }

  /// 清空所有记录
  Future<void> clear() async {
    _box!.removeAll();
  }

  /// 获取单条记录
  VectorRecord? get(String filePath) {
    final query = _box!.query(VectorEntity_.filePath.equals(filePath)).build();
    final entity = query.findFirst();
    query.close();
    return entity != null ? _toRecord(entity) : null;
  }

  /// 是否已索引
  bool contains(String filePath) => get(filePath) != null;

  /// 记录总数
  int get count => _box?.count() ?? 0;

  /// 所有记录
  List<VectorRecord> get allRecords => _box!.getAll().map(_toRecord).toList();

  /// HNSW 向量搜索
  ///
  /// [queryVector] 查询向量（已 L2 归一化）
  /// [topK] 返回前 K 个结果
  /// [filterType] 可选，按文件类型过滤 ('text' | 'image')
  List<VectorSearchResult> search(
    List<double> queryVector, {
    int topK = 10,
    String? filterType,
  }) {
    // 构建 HNSW 查询条件
    var condition = VectorEntity_.vector.nearestNeighborsF32(
      queryVector,
      topK,
    );

    // 按文件类型过滤
    if (filterType != null) {
      condition = condition.and(VectorEntity_.fileType.equals(filterType));
    }

    final query = _box!.query(condition).build();
    final resultsWithScores = query.findWithScores();
    query.close();

    // 转换结果：ObjectBox 返回距离（越小越相似），需转为相似度
    final results = <VectorSearchResult>[];
    for (final result in resultsWithScores) {
      final entity = result.object;
      final distance = result.score;
      // 余弦距离: distance = 1 - cosine_similarity → similarity = 1 - distance
      final similarity = 1.0 - distance;
      results.add(VectorSearchResult(
        record: _toRecord(entity),
        similarity: similarity,
      ));
    }

    // 按相似度降序排序
    results.sort((a, b) => b.similarity.compareTo(a.similarity));

    return results;
  }

  /// 关闭存储
  Future<void> close() async {
    _store?.close();
    _store = null;
    _box = null;
    _initialized = false;
  }
}
