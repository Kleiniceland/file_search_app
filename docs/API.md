# 接口定义文档 (API Reference)

> 本文档定义项目所有公开 API，按模块分层组织。
> 所有 API 均为 Dart 类方法，遵循"离线优先、进程内推理"原则。

---

## 一、嵌入引擎层 (EmbeddingEngine)

> 文件：[lib/services/embedding_engine.dart](../lib/services/embedding_engine.dart)

### 1.1 类定义

```dart
class EmbeddingEngine
```

多模态本地嵌入引擎，使用 ONNX Runtime 同时处理文本（BERT）和图像（MobileCLIP）嵌入。完全离线，推理全部在 Flutter 进程内完成。

### 1.2 常量

| 常量 | 类型 | 值 | 说明 |
|------|------|-----|------|
| `kTextEmbeddingDim` | int | 512 | BERT 文本向量维度 |
| `kImageEmbeddingDim` | int | 512 | MobileCLIP 图像向量维度 |
| `kMaxSequenceLength` | int | 128 | BERT 最大序列长度 |
| `kImageSize` | int | 224 | MobileCLIP 输入图像尺寸 |
| `kDefaultImageMean` | List<double> | [0.481, 0.458, 0.408] | CLIP 标准均值 |
| `kDefaultImageStd` | List<double> | [0.269, 0.261, 0.276] | CLIP 标准差 |

### 1.3 工厂方法

#### `init()` — 英文模型初始化

```dart
static Future<EmbeddingEngine> init({
  String textModelPath = 'assets/models/bert_onnx/model.onnx',
  String vocabPath = 'assets/models/bert_onnx/vocab.txt',
  String? imageModelPath,
  String? clipTextModelPath,
})
```

**参数**：
- `textModelPath`：BERT ONNX 模型路径
- `vocabPath`：BERT 词汇表路径
- `imageModelPath`：可选，MobileCLIP 图像编码器路径
- `clipTextModelPath`：可选，MobileCLIP 文本编码器路径（用于跨模态搜索）

**返回**：初始化完成的 `EmbeddingEngine` 实例

**异常**：模型文件不存在或加载失败时抛出异常

#### `initChinese()` — 中文模型初始化

```dart
static Future<EmbeddingEngine> initChinese({
  String textModelPath = 'assets/models/bert_chinese_onnx/model.onnx',
  String vocabPath = 'assets/models/bert_chinese_onnx/vocab.txt',
  String? imageModelPath,
  String? clipTextModelPath,
})
```

与 `init()` 类似，但默认路径指向中文 BERT 模型。

### 1.4 嵌入方法

#### `embedText()` — 文本嵌入

```dart
Future<List<double>> embedText(String text)
```

**功能**：text → BERT → Mean Pooling → L2 归一化 → 512 维向量

**参数**：
- `text`：输入文本（支持中英文）

**返回**：512 维 L2 归一化向量

**实现细节**：
- 使用 attention mask 加权平均（Mean Pooling）代替 CLS 提取
- 自动截断到 `kMaxSequenceLength` (128 tokens)
- 输出向量已 L2 归一化

**异常**：引擎已 dispose 时抛出 `StateError`

**示例**：
```dart
final vec = await engine.embedText('机器学习入门指南');
print(vec.length); // 512
```

#### `embedImage()` — 图像嵌入

```dart
Future<List<double>> embedImage(Uint8List imageBytes)
```

**功能**：bytes → MobileCLIP → L2 归一化 → 512 维向量

**参数**：
- `imageBytes`：图像字节数据（PNG/JPG）

**返回**：512 维 L2 归一化向量

**实现细节**：
- 解码优先级：`image` 包（纯 Dart）→ `dart:ui` ImageDescriptor（兜底）
- 自动 resize 到 224×224
- 使用 CLIP 标准均值/标准差归一化
- 输出向量已 L2 归一化

**异常**：
- 引擎已 dispose：`StateError`
- 图像模型未加载：`StateError`
- 图像解码失败：`ArgumentError`

**示例**：
```dart
final bytes = await File('photo.png').readAsBytes();
final vec = await engine.embedImage(bytes);
print(vec.length); // 512
```

#### `embedTextForImage()` — 跨模态文本嵌入

```dart
Future<List<double>> embedTextForImage(String text)
```

**功能**：text → CLIP tokenizer → MobileCLIP 文本编码器 → L2 归一化 → 512 维向量

**参数**：
- `text`：输入文本（英文，用于搜索图片）

**返回**：512 维 L2 归一化向量（与 `embedImage` 在同一向量空间）

**实现细节**：
- 使用 CLIP BPE 分词器
- 自动构建 attention_mask（基于 EOS token 位置）
- 最大序列长度 77
- 输出向量与图像向量可直接计算余弦相似度

**异常**：
- 引擎已 dispose：`StateError`
- MobileCLIP 文本编码器未加载：`StateError`

**示例**：
```dart
final textVec = await engine.embedTextForImage('a red car');
final imageVec = await engine.embedImage(carBytes);
// 计算余弦相似度
double sim = 0;
for (int i = 0; i < textVec.length; i++) {
  sim += textVec[i] * imageVec[i];
}
print('相似度: $sim');
```

### 1.5 批量处理

#### `embedBatch()` — 批量嵌入

```dart
Future<BatchEmbedResult> embedBatch(
  List<String> texts, {
  int batchSize = 32,
  BatchProgressCallback? onProgress,
})
```

**参数**：
- `texts`：文本列表
- `batchSize`：批大小（默认 32）
- `onProgress`：进度回调 `void Function(int current, int total, String? error)`

**返回**：`BatchEmbedResult`，包含成功向量列表和失败索引

### 1.6 资源管理

#### `dispose()` — 释放资源

```dart
Future<void> dispose()
```

释放 ONNX Runtime session 和分词器资源。调用后引擎不可再用。

---

## 二、向量存储层 (VectorStore)

> 文件：[lib/services/vector_store.dart](../lib/services/vector_store.dart)

### 2.1 数据结构

#### `VectorRecord` — 向量记录

```dart
class VectorRecord {
  final String filePath;    // 文件绝对路径
  final String fileName;    // 文件名
  final String fileType;    // 'text' | 'image'
  final String content;     // 提取的文本内容（截断前 500 字符）
  final List<double> embedding;  // 嵌入向量
  final DateTime indexedAt;      // 索引时间
  final int fileSize;            // 文件大小（字节）
}
```

#### `VectorSearchResult` — 搜索结果

```dart
class VectorSearchResult {
  final VectorRecord record;     // 文件记录
  final double similarity;       // 相似度 (0~1)
}
```

### 2.2 类定义

```dart
class VectorStore
```

基于 ObjectBox HNSW 索引的本地向量存储，支持 O(log n) 近似最近邻搜索。

### 2.3 方法

#### `init()` — 初始化

```dart
Future<void> init({String? storagePath})
```

**参数**：
- `storagePath`：存储目录路径，默认为 `.objectbox/`

#### `upsert()` — 添加或更新

```dart
Future<void> upsert(VectorRecord record)
```

按 `filePath` 唯一索引，存在则更新，不存在则插入。

#### `upsertBatch()` — 批量添加

```dart
Future<void> upsertBatch(List<VectorRecord> records)
```

#### `remove()` — 删除记录

```dart
Future<void> remove(String filePath)
```

#### `clear()` — 清空所有

```dart
Future<void> clear()
```

#### `get()` — 获取单条

```dart
VectorRecord? get(String filePath)
```

#### `contains()` — 是否已索引

```dart
bool contains(String filePath)
```

#### `search()` — HNSW 向量搜索

```dart
List<VectorSearchResult> search(
  List<double> queryVector, {
  int topK = 10,
  String? filterType,  // 'text' | 'image' | null
})
```

**参数**：
- `queryVector`：查询向量（应已 L2 归一化）
- `topK`：返回前 K 个结果
- `filterType`：可选，按文件类型过滤

**返回**：相似度降序排列的搜索结果列表

**实现细节**：
- 使用 ObjectBox `nearestNeighborsF32` HNSW 索引
- 距离转换：`similarity = 1.0 - distance`
- 支持与文件类型过滤条件组合

#### `close()` — 关闭存储

```dart
Future<void> close()
```

### 2.4 属性

| 属性 | 类型 | 说明 |
|------|------|------|
| `count` | int | 记录总数 |
| `allRecords` | List\<VectorRecord\> | 所有记录 |

---

## 三、检索逻辑层 (SearchService)

> 文件：[lib/services/search_service.dart](../lib/services/search_service.dart)

### 3.1 数据结构

#### `HybridSearchResult` — 混合搜索结果

```dart
class HybridSearchResult {
  final String filePath;
  final String fileName;
  final String fileType;        // 'text' | 'image'
  final String contentSnippet;  // 内容摘要
  final double vectorScore;     // 语义相似度 (0~1)
  final double keywordScore;    // 关键词匹配度 (0~1)
  final double finalScore;      // 融合后最终得分
  final int fileSize;
}
```

### 3.2 类定义

```dart
class SearchService
```

混合语义检索服务，融合向量语义搜索与关键词匹配。

### 3.3 构造函数

```dart
SearchService({
  required EmbeddingEngine engine,
  required VectorStore vectorStore,
  this.vectorWeight = 0.7,
})
```

**参数**：
- `engine`：嵌入引擎实例
- `vectorStore`：向量存储实例
- `vectorWeight`：向量搜索权重（0~1），默认 0.7

### 3.4 搜索方法

#### `search()` — 混合搜索

```dart
Future<List<HybridSearchResult>> search(
  String query, {
  int topK = 10,
  String? filterType,
})
```

**功能**：执行混合搜索（向量语义 + 关键词匹配）

**参数**：
- `query`：搜索查询文本
- `topK`：返回前 K 个结果
- `filterType`：可选，按文件类型过滤

**返回**：按 `finalScore` 降序排列的结果列表

**搜索流程**：
1. BERT 向量搜索文本文件（`embedText` → `VectorStore.search`）
2. MobileCLIP 文本向量搜索图片文件（`embedTextForImage` → `VectorStore.search`）
3. 关键词匹配（文件名 + 内容子串匹配）
4. 融合得分计算
5. 去重（按 `filePath`）
6. 阈值过滤
7. 截断到 topK

**融合策略**：

| 场景 | 评分公式 |
|------|----------|
| 图片文件 | `0.7 × vectorScore + 0.3 × keywordScore` |
| 文本文件 + 关键词匹配 | `0.4 × vectorScore + 0.6 × keywordScore` |
| 文本文件 + 无关键词匹配 | `0.3 × vectorScore` |

**阈值过滤**：
- 图片文件：`finalScore >= 0.03`
- 文本文件：`finalScore >= 0.15`

#### `vectorSearch()` — 纯向量搜索

```dart
Future<List<HybridSearchResult>> vectorSearch(
  String query, {
  int topK = 10,
  String? filterType,
})
```

仅向量搜索，不做关键词融合。

---

## 四、索引管道层 (PipelineService)

> 文件：[lib/services/pipeline_service.dart](../lib/services/pipeline_service.dart)

### 4.1 数据结构

#### `IndexStats` — 索引统计

```dart
class IndexStats {
  final int total;     // 总文件数
  final int success;   // 成功数
  final int failed;    // 失败数
  final int skipped;   // 跳过数（未修改）
  final Duration elapsed;  // 耗时
}
```

#### `IndexProgressCallback` — 进度回调

```dart
typedef IndexProgressCallback = void Function(
  int current,
  int total,
  String fileName,
  String? error,
);
```

### 4.2 类定义

```dart
class PipelineService
```

端到端检索管道服务，完整流程：文件导入 → 解析 → 嵌入 → 存储。

### 4.3 构造函数

```dart
PipelineService({
  required EmbeddingEngine engine,
  required VectorStore vectorStore,
})
```

### 4.4 方法

#### `indexFile()` — 索引单个文件

```dart
Future<bool> indexFile(File file)
```

**功能**：读取文件 → 解析内容 → 生成嵌入 → 存入 VectorStore

**返回**：`true` 表示成功，`false` 表示失败或跳过

**实现细节**：
- 增量索引：文件未修改则跳过
- 空文件保护：`stat.size == 0` 直接跳过
- 流式读取兜底：`readAsBytes()` 失败时使用 `openRead()`
- 图像文件：MobileCLIP 嵌入，content 存文件名
- 文本文件：解析内容 → BERT 嵌入，内容截断到 5000 字符

#### `indexDirectory()` — 索引整个目录

```dart
Future<IndexStats> indexDirectory(
  String rootPath, {
  IndexProgressCallback? onProgress,
})
```

**功能**：递归扫描目录，索引所有支持的文件

**参数**：
- `rootPath`：根目录路径
- `onProgress`：进度回调

**返回**：`IndexStats` 索引统计

**支持扩展名**：txt, pdf, docx, png, jpg, jpeg

#### `clearIndex()` — 清空索引

```dart
Future<void> clearIndex()
```

#### `removeIndex()` — 删除单个索引

```dart
Future<void> removeIndex(String filePath)
```

### 4.5 属性

| 属性 | 类型 | 说明 |
|------|------|------|
| `indexedCount` | int | 已索引文件数 |

---

## 五、文件解析层 (FileReader)

> 文件：[lib/utils/file_reader.dart](../lib/utils/file_reader.dart)

### 5.1 抽象接口

```dart
abstract class FileReader {
  Future<String> read(Uint8List bytes);
}
```

所有格式 Reader 实现此接口，返回提取的文本内容。

### 5.2 工厂方法

#### `FileReaderFactory.getReader()`

```dart
static FileReader? getReader(String filePath)
```

**参数**：文件路径

**返回**：对应格式的 Reader 实例，不支持的格式返回 null

**支持格式**：

| 扩展名 | Reader 类 | 文件 |
|--------|-----------|------|
| .pdf | PdfReader | [lib/utils/pdf_reader.dart](../lib/utils/pdf_reader.dart) |
| .docx | DocxReader | [lib/utils/docx_reader.dart](../lib/utils/docx_reader.dart) |
| .png | PngReader | [lib/utils/png_reader.dart](../lib/utils/png_reader.dart) |
| .jpg/.jpeg | JpgReader | [lib/utils/jpg_reader.dart](../lib/utils/jpg_reader.dart) |

### 5.3 文本解码策略

TXT 文件采用三级回退：

| 优先级 | 编码 | 说明 |
|--------|------|------|
| 1 | UTF-8 | 优先尝试 |
| 2 | systemEncoding | Windows GBK/cp936 |
| 3 | latin1 | 最后兜底 |

---

## 六、分词器 (Tokenizer)

### 6.1 BERT WordPiece 分词器

> 由 `dart_wordpiece` 包提供

```dart
WordPieceTokenizer(
  vocab: vocab,
  config: TokenizerConfig(
    maxLength: 128,
    normalizeText: true,
  ),
)
```

### 6.2 CLIP BPE 分词器

> 文件：[lib/utils/clip_tokenizer.dart](../lib/utils/clip_tokenizer.dart)

```dart
class ClipTokenizer {
  static Future<ClipTokenizer> fromAssets({
    String vocabPath = 'assets/models/mobileclip_onnx/clip_vocab.json',
    String mergesPath = 'assets/models/mobileclip_onnx/clip_merges.txt',
  });

  List<int> encode(String text);  // 返回 token ID 列表
}
```

**特殊 Token**：
- BOS (startoftext): 49406
- EOS (endoftext): 49407
- 上下文长度: 77

---

## 七、UI 层 (HomePage)

> 文件：[lib/pages/home_page.dart](../lib/pages/home_page.dart)

### 7.1 主要交互

| 操作 | 方法 | 说明 |
|------|------|------|
| 选择目录 | `_pickDirectory()` | 调用 file_picker 选择搜索目录 |
| 构建索引 | `_indexDirectory()` | 调用 PipelineService 索引目录 |
| 搜索 | `_onSearch()` | 调用 SearchService 执行搜索 |
| 文件类型筛选 | `_onFilterChanged()` | 按扩展名过滤结果 |
| 预览文件 | `_previewFile()` | 打开文件预览 |

### 7.2 无障碍支持

- 所有图标添加 `semanticLabel`
- 搜索结果使用 `Semantics` 包裹，提供完整描述
- 索引进度使用 `liveRegion` 播报
- 装饰性图标使用 `ExcludeSemantics` 排除

---

## 八、错误处理约定

### 8.1 异常类型

| 异常 | 触发场景 | 处理建议 |
|------|----------|----------|
| `StateError` | 引擎已 dispose / 模型未加载 | 检查初始化流程 |
| `ArgumentError` | 图像解码失败 | 检查文件格式 |
| `FileSystemException` | 文件读取失败 | 检查权限/路径 |
| `FormatException` | 文本解码失败 | 尝试其他编码 |

### 8.2 降级策略

| 场景 | 降级方案 |
|------|----------|
| MobileCLIP 文本编码器未加载 | 跨模态搜索降级为文件名匹配 |
| 图像解码失败 (image 包) | 降级为 dart:ui ImageDescriptor |
| 文件读取为空 (readAsBytes) | 降级为 openRead 流式读取 |
| ONNX asset 加载失败 | 降级为直接文件路径加载 |

---

*文档版本：v1.0.0*
*更新日期：2026-08-12*
