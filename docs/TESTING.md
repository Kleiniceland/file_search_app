# 测试文档 (Testing Guide)

> 本文档描述项目的测试策略、测试套件、运行方式和性能基准。

---

## 一、测试策略

### 1.1 测试分层

```
┌─────────────────────────────────────────┐
│         集成测试 (integration_test/)      │
│   需要原生环境 (ONNX Runtime + ObjectBox) │
│   端到端验证：嵌入 → 存储 → 检索 → 排序    │
├─────────────────────────────────────────┤
│          单元测试 (test/)                 │
│   纯 Dart 环境，无需原生插件              │
│   验证：文件解析、分词、工具函数           │
└─────────────────────────────────────────┘
```

### 1.2 测试环境要求

| 要求 | 单元测试 | 集成测试 |
|------|----------|----------|
| Flutter SDK | ≥ 3.0.0 | ≥ 3.0.0 |
| 操作系统 | 任意 | Windows（主要）/ macOS / Linux |
| 原生编译 | 不需要 | 需要（CMake / Visual Studio） |
| 模型文件 | 不需要 | 需要（assets/models/） |
| 运行时间 | < 5 秒 | 30-120 秒 |

---

## 二、测试套件总览

### 2.1 单元测试（test/）

| 文件 | 测试数 | 说明 |
|------|--------|------|
| [file_reader_factory_test.dart](../test/file_reader_factory_test.dart) | 8 | 工厂方法分发验证 |
| [pdf_reader_test.dart](../test/pdf_reader_test.dart) | 3 | PDF 文本提取 |
| [docx_reader_test.dart](../test/docx_reader_test.dart) | 4 | DOCX 文本提取 |
| [image_readers_test.dart](../test/image_readers_test.dart) | 2 | PNG/JPG Reader 存根验证 |
| [onnx_spike_test.dart](../test/onnx_spike_test.dart) | 1 | ONNX Runtime 基础验证 |
| **合计** | **18** | |

> **历史结论**：`tflite_spike_test.dart` 已删除。该测试验证了 tflite_flutter 在 Windows 桌面存在未解决的 DLL 加载问题，项目已切换到 ONNX Runtime。详见 [结项报告](PROJECT_FINAL_REPORT.md) 技术决策 1。

### 2.2 集成测试（integration_test/）

| 文件 | 测试数 | 说明 |
|------|--------|------|
| [embedding_engine_test.dart](../integration_test/embedding_engine_test.dart) | 15 | 嵌入引擎基础功能 + 批量处理 |
| [embedding_accuracy_test.dart](../integration_test/embedding_accuracy_test.dart) | 11 | 英文嵌入准确性 + 跨模态验证 |
| [cross_modal_search_test.dart](../integration_test/cross_modal_search_test.dart) | 11 | 跨模态搜索（CLIP） |
| [object_scene_recognition_test.dart](../integration_test/object_scene_recognition_test.dart) | 10 | 物体/场景识别 + 零样本分类 |
| [pipeline_e2e_test.dart](../integration_test/pipeline_e2e_test.dart) | 10 | 端到端管道 |
| [retrieval_benchmark_test.dart](../integration_test/retrieval_benchmark_test.dart) | 1 (12 查询) | 检索基准测试 |
| **合计** | **58** | |

### 2.3 测试总计

| 类别 | 文件数 | 测试用例数 |
|------|--------|------------|
| 单元测试 | 5 | 18 |
| 集成测试 | 6 | 58 |
| **总计** | **11** | **76** |

---

## 三、运行测试

### 3.1 运行全部单元测试

```bash
flutter test test/
```

### 3.2 运行单个测试文件

```bash
flutter test test/pdf_reader_test.dart
```

### 3.3 运行集成测试（Windows 桌面）

```bash
# 跨模态搜索测试
flutter test integration_test/cross_modal_search_test.dart -d windows

# 端到端管道测试
flutter test integration_test/pipeline_e2e_test.dart -d windows

# 检索基准测试
flutter test integration_test/retrieval_benchmark_test.dart -d windows

# 物体/场景识别测试
flutter test integration_test/object_scene_recognition_test.dart -d windows
```

### 3.4 运行所有集成测试

```bash
flutter test integration_test/ -d windows
```

### 3.5 CI/CD 自动测试

项目配置了 GitHub Actions CI：[.github/workflows/ci.yml](../.github/workflows/ci.yml)

包含三个阶段：
1. **单元测试**：`flutter test test/`
2. **代码分析**：`flutter analyze`
3. **集成测试**：`flutter test integration_test/ -d windows`（仅 Windows Runner）

---

## 四、测试用例详解

### 4.1 文件解析测试

#### PDF Reader 测试

| 用例 | 输入 | 预期输出 |
|------|------|----------|
| 正常 PDF | 含文本的 PDF 字节 | 提取的文本字符串 |
| 加密 PDF | 加密 PDF | 空字符串或异常处理 |
| 图片型 PDF | 扫描版 PDF | 空字符串（无文本层） |
| 多页 PDF | 多页文档 | 合并的全文 |

#### DOCX Reader 测试

| 用例 | 输入 | 预期输出 |
|------|------|----------|
| 正常 DOCX | 含段落文档 | 提取的文本 |
| 含表格 DOCX | 表格内容 | 表格文本 |
| 空文档 | 空 DOCX | 空字符串 |
| 格式化文档 | 含样式 | 纯文本（去格式） |

### 4.2 嵌入引擎测试

#### 文本嵌入测试

| 用例 | 验证点 | 预期 |
|------|--------|------|
| 维度验证 | 向量长度 | 512 |
| L2 归一化 | 向量模长 | ≈ 1.0 |
| 一致性 | 同文本两次嵌入 | 相同向量 |
| 区分度 | 不同文本嵌入 | 不同向量 |
| 中文支持 | 中文文本 | 正常嵌入 |
| 长文本 | > 128 tokens | 自动截断 |

#### 图像嵌入测试

| 用例 | 验证点 | 预期 |
|------|--------|------|
| 维度验证 | 向量长度 | 512 |
| L2 归一化 | 向量模长 | ≈ 1.0 |
| PNG 解码 | PNG 字节 | 正常嵌入 |
| JPG 解码 | JPG 字节 | 正常嵌入 |
| 空字节 | 空字节数组 | 抛出 ArgumentError |
| dart:ui 降级 | image 包无法解码 | 降级成功 |

### 4.3 跨模态搜索测试

| 用例 | 验证点 | 预期 |
|------|--------|------|
| 向量空间对齐 | 文本向量与图像向量 | 可计算余弦相似度 |
| 颜色识别 | "red" vs 红色图/蓝色图 | red↔red > red↔blue |
| 物体识别 | "cat" vs 猫图 | 返回猫图 |
| 场景识别 | "tree" vs 树图 | 返回树图 |
| 文件名降级 | MobileCLIP 未加载 | 降级为文件名匹配 |
| attention_mask | ONNX 输入完整性 | 不抛 Missing Input |

### 4.4 端到端管道测试

| 用例 | 验证点 | 预期 |
|------|--------|------|
| 单文件索引 | 索引后可搜索 | 搜索结果包含该文件 |
| 目录索引 | 批量索引 | 所有支持文件被索引 |
| 增量索引 | 未修改文件 | 跳过，skipped +1 |
| 空文件保护 | 0 字节文件 | 跳过，不报错 |
| 去重 | 相同文件多次索引 | 只保留一条记录 |
| 排序 | 搜索结果 | 按 finalScore 降序 |
| 文件类型过滤 | filterType 参数 | 只返回指定类型 |
| CRUD | 增删改查 | upsert/get/remove/clear 正常 |
| 中文路径 | 非英文文件名 | 正常索引 |
| 错误隔离 | 单文件失败 | 不影响其他文件 |

### 4.5 检索基准测试

基于 10 文档 / 12 查询的测试集：

| 指标 | 定义 | 数值 | 评价 |
|------|------|------|------|
| MRR | 平均倒数排名 | 0.9583 | 优秀 |
| Recall@5 | 前 5 召回率 | 0.8750 | 良好 |
| Precision@5 | 前 5 精确率 | 0.3500 | 合理 |
| F1 | F1 分数 | 0.5000 | 良好 |

---

## 五、测试数据生成

### 5.1 集成测试内置数据

集成测试使用 `image` 包程序生成测试文件，无需外部依赖：

```dart
// 生成纯色测试图
Uint8List _solidColorPng(int r, int g, int b) {
  final image = img.Image(width: 224, height: 224);
  img.fill(image, color: img.ColorRgba8(r, g, b, 255));
  return Uint8List.fromList(img.encodePng(image));
}

// 生成带形状的测试图（模拟物体）
Uint8List _shapesPng({...}) { ... }
```

### 5.2 测试文件类型

| 类型 | 生成方式 | 用途 |
|------|----------|------|
| 纯色图 | `_solidColorPng` | 颜色识别测试 |
| 几何形状图 | `_shapesPng` | 物体/场景识别测试 |
| 文本文件 | 内置字符串 | 文本搜索测试 |
| 混合文档 | 多种格式 | 端到端管道测试 |

---

## 六、性能基准

### 6.1 检索性能

| 文档库规模 | 搜索延迟 | 索引吞吐 |
|------------|----------|----------|
| 10 文档 | < 100ms | ~5 文件/秒 |
| 100 文档 | < 200ms | ~5 文件/秒 |
| 1000 文档 | < 500ms（预期） | ~5 文件/秒 |

### 6.2 内存占用

| 组件 | 内存 |
|------|------|
| BERT 中文模型 | ~114 MB |
| MobileCLIP 图像编码器 | ~85 MB |
| MobileCLIP 文本编码器 | ~162 MB |
| ObjectBox 向量存储 | ~10 MB（10 文档） |
| Flutter UI + 运行时 | ~100 MB |
| **总计** | **~470 MB** |

### 6.3 模型加载时间

| 模型 | 加载时间 |
|------|----------|
| BERT 中文 | ~2 秒 |
| MobileCLIP 图像编码器 | ~1 秒 |
| MobileCLIP 文本编码器（延迟加载） | ~3 秒 |

---

## 七、已知限制

### 7.1 测试覆盖限制

| 限制 | 原因 | 影响 |
|------|------|------|
| 跨平台测试缺失 | 仅 Windows 验证 | macOS/Linux/移动端行为未知 |
| 大规模性能测试缺失 | 测试集仅 10 文档 | 1000+ 文档性能未验证 |
| 真实图片识别测试缺失 | 使用几何形状模拟 | 真实照片识别效果未验证 |
| OCR 测试缺失 | 未实现 OCR | 图片内文字无法识别 |

### 7.2 CLIP 模型限制

| 限制 | 说明 |
|------|------|
| 中文不支持 | MobileCLIP 文本编码器为英文模型 |
| 纯色图区分度低 | 纯色图缺乏语义特征，CLIP 相似度区分有限 |
| 绝对相似度低 | CLIP 跨模态相似度通常 0.05-0.20，依赖相对排序 |

---

## 八、测试最佳实践

### 8.1 编写新测试

```dart
// 1. 集成测试必须使用正确的 binding
setUpAll(() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 初始化引擎和存储
});

// 2. 清理资源
tearDownAll(() async {
  await vectorStore.clear();
  await engine.dispose();
});

// 3. 使用临时目录
tempDir = Directory.systemTemp.createTempSync('test_');

// 4. 使用相对路径访问模型
final projectRoot = Directory.current.path;
engine = await EmbeddingEngine.initChinese(
  textModelPath: '$projectRoot/assets/models/bert_chinese_onnx/model.onnx',
);
```

### 8.2 调试失败测试

```bash
# 详细输出
flutter test integration_test/xxx_test.dart -d windows --verbose

# 只运行单个测试
flutter test integration_test/xxx_test.dart -d windows --name "特定测试名"

# 不删除 build 缓存（加速重复运行）
flutter test integration_test/xxx_test.dart -d windows --no-pub
```

---

## 九、持续集成

### 9.1 CI 配置

文件：[.github/workflows/ci.yml](../.github/workflows/ci.yml)

```yaml
jobs:
  unit-test:
    - flutter test test/
  analyze:
    - flutter analyze
  integration-test:
    - flutter test integration_test/ -d windows
```

### 9.2 测试报告

CI 运行后生成：
- 测试通过/失败数
- 代码覆盖率（待集成）
- 性能基准趋势（待集成）

---

*文档版本：v1.0.0*
*更新日期：2026-08-12*
