# 部署指南

## 一键部署

最简单的方式是使用一键部署脚本：

```powershell
# 完整部署（环境检查 + 依赖 + 模型 + 构建 + 测试）
.\scripts\deploy.ps1

# 跳过模型下载（已手动准备好模型时）
.\scripts\deploy.ps1 -SkipModels

# 跳过集成测试（加速部署）
.\scripts\deploy.ps1 -SkipTests

# 部署完成后直接启动应用
.\scripts\deploy.ps1 -RunApp
```

脚本会自动完成：
1. 环境检查（Flutter / Python / Visual Studio）
2. Flutter 依赖安装
3. ObjectBox 代码生成
4. 模型权重下载/生成
5. 构建验证
6. 集成测试（可选）

---

## 手动部署

### 前置条件

#### 开发环境

1. **Flutter SDK** >= 3.0.0
   ```bash
   # 下载: https://docs.flutter.dev/get-started/install/windows
   flutter doctor
   ```

2. **Visual Studio 2022** (含 "Desktop development with C++" 工作负载)
   - 用于编译 Windows 原生代码 (ONNX Runtime, ObjectBox FFI)

3. **Python 3.11+** (仅模型导出需要)
   ```bash
   pip install torch open_clip_torch transformers pillow onnxruntime
   ```

### 模型文件

确保以下模型文件已就位：

```
assets/models/
├── bert_chinese_onnx/
│   ├── model.onnx                    # BERT 中文文本嵌入模型 (~114 MB)
│   ├── vocab.txt                     # WordPiece 词表
│   └── config.json
├── bert_onnx/
│   ├── model.onnx                    # BERT 英文文本嵌入模型
│   ├── vocab.txt
│   └── config.json
└── mobileclip_onnx/
    ├── image_encoder.onnx            # MobileCLIP 图像编码器 (~85 MB)
    ├── image_encoder.onnx.data       # 外部数据文件
    ├── text_encoder.onnx             # MobileCLIP 文本编码器 (~162 MB)
    ├── clip_vocab.json               # CLIP BPE 词表
    ├── clip_merges.txt               # BPE 合并规则
    └── preprocess_config.json        # 图像预处理配置
```

#### 方式一：使用下载脚本（推荐）

```powershell
.\scripts\download_models.ps1
```

脚本会自动：
- 检查已有模型文件
- 安装 Python 依赖
- 调用导出脚本生成缺失模型
- 验证所有模型完整性

#### 方式二：手动导出

```bash
# BERT 中文模型
python scripts/export_bert_chinese_onnx.py

# MobileCLIP 多模态模型
python scripts/export_mobileclip_multimodal.py
```

#### 方式三：从 HuggingFace 手动下载

- BERT 中文：https://huggingface.co/uer/chinese_roberta_L-6_H-512
- MobileCLIP：https://github.com/apple/ml-mobileclip

下载后需用上述 Python 脚本转换为 ONNX 格式。

### 构建步骤

#### 1. 安装依赖

```bash
flutter pub get
```

#### 2. 生成 ObjectBox 代码

```bash
dart run build_runner build --delete-conflicting-outputs
```

> 如果修改了 `lib/services/objectbox_model.dart` 中的实体定义，需重新执行此命令。

#### 3. 开发模式运行

```bash
flutter run -d windows
```

#### 4. 发布模式构建

```bash
flutter build windows --release
```

构建产物位于 `build/windows/x64/runner/Release/`。

#### 5. 分发

将 `Release/` 目录打包为 ZIP，包含：
- `file_search_app.exe`
- 所有 DLL 文件 (flutter_windows.dll, objectbox.dll 等)
- `data/` 目录 (Flutter assets, 包含模型文件)

## 测试

### 集成测试 (需 Windows 桌面)

```bash
# 跨模态搜索测试 (11 个测试)
flutter test integration_test/cross_modal_search_test.dart -d windows

# 端到端管道测试
flutter test integration_test/pipeline_e2e_test.dart -d windows

# 检索准确性基准
flutter test integration_test/retrieval_benchmark_test.dart -d windows

# 物体/场景识别测试
flutter test integration_test/object_scene_recognition_test.dart -d windows

# 嵌入准确性测试 (英文)
flutter test integration_test/embedding_accuracy_test.dart -d windows

# 嵌入准确性测试 (中文)
flutter test integration_test/embedding_accuracy_chinese_test.dart -d windows
```

### 单元测试 (纯 Dart)

```bash
flutter test test/
```

## 常见问题

### Q: ObjectBox 报 "Failed to load dynamic library"

确保 `objectbox_flutter_libs` 已添加到 `pubspec.yaml` 的 dependencies 中，然后执行 `flutter pub get` 和重新构建。

### Q: ONNX Runtime 报 GBK 编码错误

这是 flutter_onnxruntime 在 Windows 上的已知问题。使用文件路径加载模型（而非 asset），可绕过此问题。

### Q: 模型加载内存不足

BERT (114 MB) + MobileCLIP 图像 (85 MB) + MobileCLIP 文本 (162 MB) = ~360 MB。如内存不足，可注释掉 CLIP 文本编码器的延迟加载，跨模态搜索将回退到文件名匹配。

### Q: build_runner 报冲突

```bash
dart run build_runner build --delete-conflicting-outputs
```

### Q: PowerShell 执行策略阻止脚本运行

以管理员身份运行 PowerShell，执行：
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

### Q: HuggingFace 下载慢

设置镜像：
```powershell
$env:HF_ENDPOINT = "https://hf-mirror.com"
```

下载脚本已默认使用此镜像。

## 数据存储位置

- ObjectBox 数据: `./.objectbox/` (应用运行目录下)
- Hive 旧数据: `./.hive/` (已弃用，可安全删除)
