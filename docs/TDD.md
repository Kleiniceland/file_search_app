# 技术设计文档 (TDD)

## 1. 系统架构

### 1.1 分层设计

```
┌─────────────────────────────────────────┐
│              UI 层 (home_page)            │
│   搜索框 | 结果列表 | 筛选器 | 无障碍      │
├─────────────────────────────────────────┤
│            检索逻辑层 (SearchService)      │
│   混合排序 | 去重 | 跨模态融合             │
├─────────────────────────────────────────┤
│          嵌入引擎层 (EmbeddingEngine)      │
│   BERT 文本 | MobileCLIP 图像 | CLIP 文本  │
├─────────────────────────────────────────┤
│      文件 I/O + 解析层 (PipelineService)   │
│   目录扫描 | FileReader | 文本提取         │
├─────────────────────────────────────────┤
│        向量存储层 (VectorStore)            │
│   ObjectBox HNSW | 余弦相似度 | 持久化     │
└─────────────────────────────────────────┘
```

### 1.2 模块职责

| 模块 | 职责 | 关键接口 |
|------|------|----------|
| EmbeddingEngine | 多模态嵌入生成 | embedText(), embedImage(), embedTextForImage() |
| VectorStore | 向量持久化与检索 | upsert(), search(), get(), clear() |
| SearchService | 混合检索与排序 | search() → List<HybridSearchResult> |
| PipelineService | 文件导入管道 | indexDirectory() → IndexStats |
| FileReader | 文件文本提取 (抽象) | read(Uint8List) → Future<String> |

## 2. 关键设计决策

### 2.1 ONNX Runtime 替代 TensorFlow Lite

**决策**: 使用 flutter_onnxruntime 替代 tflite_flutter

**原因**: tflite_flutter 在 Windows 桌面存在未解决的 DLL 加载问题；onnxruntime 是跨平台推理引擎的成熟选择。

### 2.2 ObjectBox HNSW 替代 Hive 暴力扫描

**决策**: 使用 ObjectBox 4.x 的 HNSW 向量索引

**原因**:
- Hive 暴力扫描为 O(n)，大规模文件库性能下降
- ObjectBox 提供 O(log n) HNSW 近似最近邻搜索
- 原生支持余弦相似度距离类型
- 进程内运行（FFI），无 Python sidecar
- 支持 Windows/macOS/Linux 桌面平台

### 2.3 BERT 512 维轻量模型

**决策**: 使用 uer/chinese_roberta_L-6_H-512 (512 维) 替代标准 BERT-base (768 维)

**原因**: 标准 BERT-base (400 MB) + MobileCLIP 图像 (85 MB) + 文本编码器 (162 MB) 总内存 ~650 MB 超出环境限制。轻量版 114 MB，总内存 ~360 MB。

### 2.4 MobileCLIP 文本编码器延迟加载

**决策**: CLIP 文本编码器在 BERT 和图像编码器加载后异步延迟加载

**原因**: 三模型同时加载内存峰值过高。延迟加载使应用快速启动，跨模态搜索功能就绪后更新 UI 状态。

### 2.5 attention_mask 修复

**问题**: text_encoder.onnx 的 Equal 节点要求 attention_mask 输入

**解决方案**: 在 embedTextForImage 中通过定位 inputIds 中第一个 EOS token (49407) 构建 attention_mask：真实 token (BOS + text + EOS) 为 1，padding 为 0。

## 3. 数据流

### 3.1 索引流式管道

```
目录扫描
  → 文件类型判断 (FileReaderFactory.getReader)
  → 文本提取 (compute() isolate)
  → 嵌入生成 (BERT embedText / MobileCLIP embedImage)
  → L2 归一化
  → ObjectBox 存储 (HNSW 索引自动更新)
```

### 3.2 搜索流程

```
用户查询
  → BERT embedText(query) → 文本向量搜索 (HNSW)
  → CLIP embedTextForImage(query) → 图像向量搜索 (HNSW)
  → 关键词匹配得分计算
  → 融合排序 (0.4×语义 + 0.6×关键词)
  → filePath 去重
  → 阈值过滤 (≥ 0.15)
  → Top-K 截断
```

## 4. 向量存储设计

### 4.1 ObjectBox 实体

```dart
@Entity()
class VectorEntity {
  @Id() int id = 0;
  @Index() @Unique() String? filePath;      // 唯一标识
  String? fileName;
  @Index() String? fileType;                 // text / image
  String? content;                           // 提取的文本
  @HnswIndex(dimensions: 512, distanceType: VectorDistanceType.cosine)
  @Property(type: PropertyType.floatVector)
  List<double>? vector;                      // 512 维嵌入
  int? indexedAt;                            // 毫秒时间戳
  int? fileSize;
}
```

### 4.2 HNSW 查询

```dart
var condition = VectorEntity_.vector.nearestNeighborsF32(queryVector, topK);
if (filterType != null) {
  condition = condition.and(VectorEntity_.fileType.equals(filterType));
}
final results = box.query(condition).build().findWithScores();
// 距离 → 相似度: similarity = 1.0 - distance
```

## 5. 无障碍设计

### 5.1 WCAG 2.1 AA 合规

| 要求 | 实现 |
|------|------|
| 所有交互元素有可访问名称 | IconButton.tooltip, TextField.labelText, Semantics.label |
| 状态变化播报 | Semantics(liveRegion: true) |
| 装饰性元素排除 | ExcludeSemantics |
| 对比度 ≥ 4.5:1 | grey[600] → grey[700] |
| 进度信息可访问 | LinearProgressIndicator.semanticsLabel |
| 搜索结果描述 | Semantics(label: "结果 N: 文件名, 匹配度 X%...") |

## 6. 技术栈偏离记录

| 计划 | 实际 | 原因 |
|------|------|------|
| TensorFlow Lite | ONNX Runtime | tflite_flutter Windows DLL 不可用 |
| Chroma DB | ObjectBox | Chroma DB 需 Python sidecar，违反进程内约束 |
| PDFium + Tika | syncfusion_flutter_pdf | Dart 原生库，无需 JVM |
| BERT 768 维 | 512 维轻量版 | 内存限制 (650 MB → 360 MB) |
| Google Test | flutter_test | 桌面端适用 |
