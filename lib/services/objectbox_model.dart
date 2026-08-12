/// ObjectBox 实体定义 - 向量记录
///
/// 使用 HNSW 索引实现 O(log n) 近似最近邻搜索，
/// 替代 Hive 暴力扫描的 O(n) 余弦相似度计算。
library;

import 'package:objectbox/objectbox.dart';

/// 向量维度（文本和图像均为 512）
const int kVectorDimensions = 512;

@Entity()
class VectorEntity {
  VectorEntity();

  VectorEntity.fromRecord({
    required this.filePath,
    required this.fileName,
    required this.fileType,
    required this.content,
    required List<double> embedding,
    required this.indexedAt,
    required this.fileSize,
  }) : vector = embedding;

  @Id()
  int id = 0;

  /// 文件完整路径（唯一标识）
  @Index()
  @Unique()
  String? filePath;

  String? fileName;

  /// 文件类型: text / image
  @Index()
  String? fileType;

  /// 提取的文本内容
  String? content;

  /// 嵌入向量（HNSW 索引，余弦相似度）
  @HnswIndex(dimensions: kVectorDimensions, distanceType: VectorDistanceType.cosine)
  @Property(type: PropertyType.floatVector)
  List<double>? vector;

  /// 索引时间戳（毫秒）
  int? indexedAt;

  /// 文件大小（字节）
  int? fileSize;
}
