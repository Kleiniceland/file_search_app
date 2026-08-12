# 本地多模态语义搜索引擎

离线优先、无障碍、跨平台的多模态本地文件检索工具。支持对 PDF、Word、TXT、图片等非结构化内容进行语义搜索，无需上传任何数据到云端。

## 核心特性

- **多模态语义搜索**：同时支持文本内容（BERT 嵌入）和图像内容（MobileCLIP 嵌入）的语义检索
- **跨模态搜索**：用自然语言搜索图片（如输入"红色"找到红色图片）
- **混合检索**：关键词匹配 + 语义相似度融合排序
- **完全离线**：所有模型推理在本地 CPU 完成，无网络依赖
- **无障碍支持**：遵循 WCAG 2.1 AA 标准，支持屏幕阅读器
- **HNSW 向量索引**：ObjectBox 提供 O(log n) 近似最近邻搜索

## 技术栈

| 类别 | 技术 |
|------|------|
| 框架 | Flutter (Windows 桌面) |
| 文本嵌入 | BERT-base ONNX (512 维, 中文 roberta 轻量版) |
| 图像嵌入 | MobileCLIP-S1 ONNX (512 维) |
| 跨模态嵌入 | MobileCLIP 文本编码器 (512 维, 与图像共享向量空间) |
| 向量存储 | ObjectBox (HNSW 索引, 余弦相似度) |
| 文档解析 | syncfusion_flutter_pdf / docx_dart / 自实现 Reader |
| 推理引擎 | flutter_onnxruntime |
| 分词 | dart_wordpiece (BERT) / 自实现 BPE (CLIP) |

## 支持的文件格式

| 格式 | 文本提取 | 图像嵌入 |
|------|----------|----------|
| TXT | UTF-8 / GBK / Latin1 三级回退 | - |
| PDF | syncfusion_flutter_pdf | - |
| DOCX | docx_dart | - |
| PNG | - | MobileCLIP |
| JPG/JPEG | - | MobileCLIP |

## 架构概览

```
用户输入查询
    │
    ▼
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│  SearchService │◄──│  EmbeddingEngine  │◄──│  ONNX Runtime │
│  (混合检索)    │   │  (BERT + CLIP)    │   │  (本地推理)    │
└──────┬──────┘     └──────────────────┘     └─────────────┘
       │
       ▼
┌─────────────┐     ┌──────────────────┐
│  VectorStore  │◄──│  PipelineService   │
│  (ObjectBox   │   │  (文件导入→解析→   │
│   HNSW 索引)  │   │   嵌入→存储)       │
└─────────────┘     └──────────────────┘
```

## 快速开始

### 环境要求

- Flutter SDK >= 3.0.0
- Dart SDK >= 3.0.0
- Windows: Visual Studio 2022 with "Desktop development with C++" workload
- Python 3.11+ (仅模型导出脚本需要)

### 安装

```bash
# 克隆项目
git clone <repo-url>
cd file_search_app

# 安装依赖
flutter pub get

# 生成 ObjectBox 代码
dart run build_runner build --delete-conflicting-outputs
```

### 运行

```bash
flutter run -d windows
```

### 测试

```bash
# 集成测试（需要 Windows 桌面环境，原生 ONNX Runtime + ObjectBox）
flutter test integration_test/cross_modal_search_test.dart -d windows
flutter test integration_test/pipeline_e2e_test.dart -d windows
flutter test integration_test/retrieval_benchmark_test.dart -d windows

# 单元测试（纯 Dart，无需原生环境）
flutter test test/
```

## 使用指南

1. 启动应用后，点击工具栏文件夹图标选择搜索目录
2. 点击构建图标开始索引（自动解析、嵌入、存储所有支持的文件）
3. 在搜索框输入查询内容（支持自然语言）
4. 使用扩展名筛选器过滤文件类型
5. 点击结果项可预览文件内容

## 搜索评分机制

| 场景 | 评分公式 |
|------|----------|
| 文本文件 + 关键词匹配 | 0.4 × 语义相似度 + 0.6 × 关键词得分 |
| 文本文件 + 无关键词匹配 | 0.3 × 语义相似度 (阈值 ≥ 0.15) |
| 图片文件 | 0.7 × CLIP 跨模态相似度 + 0.3 × 关键词得分 |

## 项目结构

```
lib/
├── main.dart                    # 应用入口
├── pages/
│   └── home_page.dart           # 主界面 (含无障碍支持)
├── services/
│   ├── embedding_engine.dart    # 多模态嵌入引擎 (BERT + MobileCLIP)
│   ├── vector_store.dart        # ObjectBox HNSW 向量存储
│   ├── search_service.dart      # 混合语义检索
│   ├── pipeline_service.dart    # 文件导入管道
│   └── objectbox_model.dart     # ObjectBox 实体定义
├── utils/
│   ├── file_reader.dart         # 文件读取抽象接口
│   ├── pdf_reader.dart          # PDF 文本提取
│   ├── docx_reader.dart         # DOCX 文本提取
│   ├── txt_reader.dart          # TXT 文本提取
│   ├── clip_tokenizer.dart      # CLIP BPE 分词器
│   └── bert_tokenizer.dart      # BERT WordPiece 分词器
└── objectbox.g.dart             # ObjectBox 生成代码

integration_test/                # 集成测试 (需原生环境)
test/                           # 单元测试
scripts/                        # 模型导出与工具脚本
assets/models/                  # ONNX 模型文件
```

## 模型文件

| 模型 | 路径 | 大小 | 用途 |
|------|------|------|------|
| BERT (中文) | assets/models/bert_chinese_onnx/ | ~114 MB | 文本嵌入 (512 维) |
| MobileCLIP 图像编码器 | assets/models/mobileclip_onnx/image_encoder.onnx | ~85 MB | 图像嵌入 (512 维) |
| MobileCLIP 文本编码器 | assets/models/mobileclip_onnx/text_encoder.onnx | ~162 MB | 跨模态文本嵌入 (512 维) |

模型导出脚本位于 `scripts/export_mobileclip_multimodal.py`。

## 跨平台支持

| 平台 | 状态 | 说明 |
|------|------|------|
| Windows | ✅ 已验证 | 主要开发和测试平台 |
| macOS | ⚠️ 未测试 | 理论支持，需验证 ONNX Runtime |
| Linux | ⚠️ 未测试 | 理论支持 |
| Android | ⚠️ 未测试 | 需适配移动端 UI |
| iOS | ⚠️ 未测试 | 需适配移动端 UI |
| Web | ❌ 不支持 | ONNX Runtime 不支持 Web 平台 |

## 开源许可

MIT License
