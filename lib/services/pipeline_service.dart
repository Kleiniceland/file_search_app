import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import '../utils/file_reader_factory.dart';
import '../utils/file_utils.dart';
import 'embedding_engine.dart';
import 'vector_store.dart';

/// 索引进度回调
///
/// [current] 当前已处理数量
/// [total] 总数量
/// [fileName] 当前处理的文件名
/// [error] 错误信息（成功时为 null）
typedef IndexProgressCallback = void Function(
    int current, int total, String fileName, String? error);

/// 索引结果统计
class IndexStats {
  final int total;
  final int success;
  final int failed;
  final int skipped;
  final Duration elapsed;

  IndexStats({
    required this.total,
    required this.success,
    required this.failed,
    required this.skipped,
    required this.elapsed,
  });

  @override
  String toString() =>
      '总计: $total | 成功: $success | 失败: $failed | 跳过: $skipped | 耗时: ${elapsed.inSeconds}s';
}

/// 端到端检索管道服务
///
/// 完整流程：文件导入 → 解析 → 嵌入 → 存储
/// 搜索流程：查询文本 → 嵌入 → 向量搜索 + 关键词搜索 → 融合排序 → 返回结果
class PipelineService {
  final EmbeddingEngine _engine;
  final VectorStore _vectorStore;

  PipelineService({
    required EmbeddingEngine engine,
    required VectorStore vectorStore,
  })  : _engine = engine,
        _vectorStore = vectorStore;

  /// 索引单个文件
  ///
  /// 流程：读取文件 → 解析内容 → 生成嵌入 → 存入 VectorStore
  /// 如果文件已索引且未修改，则跳过。
  Future<bool> indexFile(File file) async {
    final path = file.path;
    final fileName = p.basename(path);
    final ext = path.split('.').last.toLowerCase();

    // 1. 检查是否已索引且未修改
    final existing = _vectorStore.get(path);
    if (existing != null) {
      final stat = file.statSync();
      if (existing.indexedAt.isAfter(stat.modified) &&
          existing.fileSize == stat.size) {
        return true; // 跳过未修改的文件
      }
    }

    // 2. 读取文件字节
    final stat = file.statSync();
    if (stat.size == 0) {
      print('⚠️ 跳过空文件 [$fileName]: 字节大小=0');
      return false;
    }

    // 尝试多种方式读取文件（处理中文路径等特殊情况）
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      print('⚠️ 文件读取异常 [$fileName]: $e');
      return false;
    }

    if (bytes.isEmpty) {
      // 备用方案：通过 openRead 流式读取
      try {
        final buffer = <int>[];
        await for (final chunk in file.openRead()) {
          buffer.addAll(chunk);
        }
        bytes = Uint8List.fromList(buffer);
      } catch (e) {
        print('⚠️ 文件备用读取也失败 [$fileName]: $e');
        return false;
      }
    }

    if (bytes.isEmpty) {
      print(
          '⚠️ 文件读取为空 [$fileName]: path=$path, stat.size=${stat.size}, bytes.length=${bytes.length}');
      return false;
    }

    // 3. 根据文件类型处理
    String content = '';
    List<double> embedding;
    String fileType;

    if (_isImageFile(ext)) {
      // 图像文件：用 MobileCLIP 嵌入
      fileType = 'image';
      try {
        embedding = await _engine.embedImage(bytes);
        // 图像无文本内容，用文件名作为内容
        content = fileName;
      } catch (e) {
        print('❌ 图像嵌入失败 [$fileName]: $e');
        return false;
      }
    } else {
      // 文本类文件：解析内容 → BERT 嵌入
      fileType = 'text';
      content = await _extractContent(file, ext, bytes);
      if (content.trim().isEmpty) {
        // 无文本内容，用文件名嵌入
        content = fileName;
      }

      // 截断到 BERT 最大处理长度（避免超长文本）
      final truncated =
          content.length > 5000 ? content.substring(0, 5000) : content;
      try {
        embedding = await _engine.embedText(truncated);
      } catch (e) {
        print('❌ 文本嵌入失败 [$fileName]: $e');
        return false;
      }
    }

    // 4. 存入 VectorStore
    final record = VectorRecord(
      filePath: path,
      fileName: fileName,
      fileType: fileType,
      content: content.length > 500 ? content.substring(0, 500) : content,
      embedding: embedding,
      indexedAt: DateTime.now(),
      fileSize: stat.size,
    );

    await _vectorStore.upsert(record);
    return true;
  }

  /// 索引整个目录
  ///
  /// 递归扫描目录下的所有支持文件，逐一索引。
  Future<IndexStats> indexDirectory(
    String rootPath, {
    IndexProgressCallback? onProgress,
  }) async {
    final watch = Stopwatch()..start();
    final dir = Directory(rootPath);
    if (!dir.existsSync()) {
      return IndexStats(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        elapsed: Duration.zero,
      );
    }

    // 收集所有支持的文件
    final files = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final ext = entity.path.split('.').last.toLowerCase();
      if (supportedExtensions.contains(ext)) {
        files.add(entity);
      }
    }

    int success = 0;
    int failed = 0;
    int skipped = 0;
    final total = files.length;

    for (int i = 0; i < files.length; i++) {
      final file = files[i];
      final fileName = p.basename(file.path);

      // 检查是否可跳过
      final existing = _vectorStore.get(file.path);
      if (existing != null) {
        final stat = file.statSync();
        if (existing.indexedAt.isAfter(stat.modified) &&
            existing.fileSize == stat.size) {
          skipped++;
          onProgress?.call(i + 1, total, fileName, null);
          continue;
        }
      }

      // 索引文件
      try {
        final ok = await indexFile(file);
        if (ok) {
          success++;
          onProgress?.call(i + 1, total, fileName, null);
        } else {
          failed++;
          onProgress?.call(i + 1, total, fileName, '嵌入失败');
        }
      } catch (e) {
        failed++;
        onProgress?.call(i + 1, total, fileName, e.toString());
      }
    }

    watch.stop();
    return IndexStats(
      total: total,
      success: success,
      failed: failed,
      skipped: skipped,
      elapsed: watch.elapsed,
    );
  }

  /// 提取文件文本内容
  Future<String> _extractContent(File file, String ext, List<int> bytes) async {
    // TXT 文件直接读取
    if (ext == 'txt') {
      try {
        return await file.readAsString();
      } catch (_) {
        return '';
      }
    }

    // 其他格式走 FileReader 工厂
    final reader = FileReaderFactory.getReader(file.path);
    if (reader == null) return '';

    try {
      final uint8bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      return await reader.read(uint8bytes);
    } catch (_) {
      return '';
    }
  }

  /// 判断是否为图像文件
  bool _isImageFile(String ext) {
    return ext == 'png' || ext == 'jpg' || ext == 'jpeg';
  }

  /// 获取已索引文件数
  int get indexedCount => _vectorStore.count;

  /// 清空索引
  Future<void> clearIndex() async {
    await _vectorStore.clear();
  }

  /// 删除单个文件的索引
  Future<void> removeIndex(String filePath) async {
    await _vectorStore.remove(filePath);
  }
}
