import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:dart_wordpiece/dart_wordpiece.dart';
import 'package:image/image.dart' as img;
import '../utils/clip_tokenizer.dart';

/// 批量嵌入进度回调
///
/// [current] 当前已处理的数量
/// [total] 总数量
/// [error] 当前项的错误信息（成功时为 null）
typedef BatchProgressCallback = void Function(
    int current, int total, String? error);

/// 批量嵌入结果
class BatchEmbedResult {
  /// 成功生成的嵌入向量
  final List<List<double>> embeddings;

  /// 失败项的索引列表
  final List<int> failedIndices;

  BatchEmbedResult({
    required this.embeddings,
    required this.failedIndices,
  });

  /// 成功数量
  int get successCount => embeddings.length;

  /// 失败数量
  int get failureCount => failedIndices.length;
}

/// 多模态本地嵌入引擎（Week 3）
///
/// 使用 ONNX Runtime 同时处理文本（BERT）和图像（MobileCLIP）嵌入。
/// 完全离线，推理全部在 Flutter 进程内完成。
class EmbeddingEngine {
  EmbeddingEngine._({
    required OnnxRuntime ort,
    required OrtSession textSession,
    required OrtSession? imageSession,
    required OrtSession? clipTextSession,
    required WordPieceTokenizer tokenizer,
    required ClipTokenizer? clipTokenizer,
    required List<double> imageMean,
    required List<double> imageStd,
  })  : _ort = ort,
        _textSession = textSession,
        _imageSession = imageSession,
        _clipTextSession = clipTextSession,
        _tokenizer = tokenizer,
        _clipTokenizer = clipTokenizer,
        _imageMean = imageMean,
        _imageStd = imageStd;

  final OnnxRuntime _ort;
  final OrtSession _textSession;
  final OrtSession? _imageSession;
  OrtSession? _clipTextSession;
  final WordPieceTokenizer _tokenizer;
  ClipTokenizer? _clipTokenizer;

  bool _disposed = false;

  /// BERT 向量维度
  /// 注意：使用轻量模型 uer/chinese_roberta_L-6_H-512，维度为 512
  static const int kTextEmbeddingDim = 512;

  /// MobileCLIP 向量维度
  static const int kImageEmbeddingDim = 512;

  /// 最大序列长度
  static const int kMaxSequenceLength = 128;

  /// 图像预处理参数（MobileCLIP 默认）
  /// 注意：这是 CLIP 标准值，不是 ImageNet 值
  /// 实际运行时会从 preprocess_config.json 动态读取覆盖
  static const int kImageSize = 224;
  static const List<double> kDefaultImageMean = [
    0.48145466,
    0.4578275,
    0.40821073
  ];
  static const List<double> kDefaultImageStd = [
    0.26862954,
    0.26130258,
    0.27577711
  ];

  /// 运行时图像预处理参数（从 config.json 读取，默认用 CLIP 标准值）
  List<double> _imageMean = kDefaultImageMean;
  List<double> _imageStd = kDefaultImageStd;

  /// 从 assets 加载并初始化引擎
  ///
  /// [imageModelPath] 可选，如果为 null 则不加载图像模型（embedImage 会抛异常）
  /// [clipTextModelPath] 可选，MobileCLIP 文本编码器，用于跨模态搜索
  static Future<EmbeddingEngine> init({
    String textModelPath = 'assets/models/bert_onnx/model.onnx',
    String vocabPath = 'assets/models/bert_onnx/vocab.txt',
    String? imageModelPath,
    String? clipTextModelPath,
  }) async {
    final ort = OnnxRuntime();

    // 加载文本分词器
    final vocabRaw = await rootBundle.loadString(vocabPath);
    final vocab = VocabLoader.fromString(vocabRaw);
    final tokenizer = WordPieceTokenizer(
      vocab: vocab,
      config: TokenizerConfig(
        maxLength: kMaxSequenceLength,
        normalizeText: true,
      ),
    );

    // 加载文本 ONNX 模型
    final textSession = await ort.createSessionFromAsset(textModelPath);

    // 图像模型可选（MobileCLIP 尚未导出时跳过）
    OrtSession? imageSession;
    List<double> imageMean = kDefaultImageMean;
    List<double> imageStd = kDefaultImageStd;
    if (imageModelPath != null) {
      print('🔧 [init] 正在加载 MobileCLIP 模型: $imageModelPath');

      // 尝试 1: 从 asset 加载
      try {
        imageSession = await ort.createSessionFromAsset(imageModelPath);
        print('   ✅ MobileCLIP 模型加载成功 (asset)');
      } catch (e) {
        print('   ⚠️  asset 加载失败: $e');
        // 尝试 2: 从文件路径直接加载（绕过 asset 打包问题）
        try {
          final file = File(imageModelPath);
          if (await file.exists()) {
            imageSession = await ort.createSession(imageModelPath);
            print('   ✅ MobileCLIP 模型加载成功 (file)');
          } else {
            print('   ⚠️  文件不存在: $imageModelPath');
          }
        } catch (e2) {
          print('   ❌ 文件加载也失败: $e2');
        }
      }

      if (imageSession != null) {
        // 动态读取预处理配置（mean/std），不硬编码
        try {
          print('🔧 [init] 正在读取 preprocess_config.json');
          final configStr = await rootBundle.loadString(
            'assets/models/mobileclip_onnx/preprocess_config.json',
          );
          final config = jsonDecode(configStr) as Map<String, dynamic>;
          final mean = (config['mean'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
          final std = (config['std'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
          if (mean.length == 3 && std.length == 3) {
            imageMean = mean;
            imageStd = std;
            print('   ✅ 已加载 MobileCLIP 预处理配置: mean=$mean, std=$std');
          }
        } catch (e, st) {
          print('   ⚠️  读取 preprocess_config.json 失败，使用 CLIP 默认值: $e');
          print('   堆栈: $st');
        }
      }
    }

    // 加载 MobileCLIP 文本编码器（可选，用于跨模态搜索）
    OrtSession? clipTextSession;
    ClipTokenizer? clipTokenizer;
    if (clipTextModelPath != null) {
      print('🔧 [init] 正在加载 MobileCLIP 文本编码器: $clipTextModelPath');
      try {
        clipTextSession = await ort.createSessionFromAsset(clipTextModelPath);
        clipTokenizer = await ClipTokenizer.fromAssets();
        print('   ✅ MobileCLIP 文本编码器加载成功');
      } catch (e) {
        print('   ⚠️  MobileCLIP 文本编码器加载失败: $e');
        try {
          final file = File(clipTextModelPath);
          if (await file.exists()) {
            clipTextSession = await ort.createSession(clipTextModelPath);
            clipTokenizer = await ClipTokenizer.fromAssets();
            print('   ✅ MobileCLIP 文本编码器加载成功 (file)');
          }
        } catch (e2) {
          print('   ❌ 文件加载也失败: $e2');
        }
      }
    }

    return EmbeddingEngine._(
      ort: ort,
      textSession: textSession,
      imageSession: imageSession,
      clipTextSession: clipTextSession,
      tokenizer: tokenizer,
      clipTokenizer: clipTokenizer,
      imageMean: imageMean,
      imageStd: imageStd,
    );
  }

  /// 使用中文 BERT 模型初始化（bert-base-chinese）
  ///
  /// 与 [init] 类似，但默认路径指向中文模型
  static Future<EmbeddingEngine> initChinese({
    String textModelPath = 'assets/models/bert_chinese_onnx/model.onnx',
    String vocabPath = 'assets/models/bert_chinese_onnx/vocab.txt',
    String? imageModelPath,
    String? clipTextModelPath,
  }) {
    return init(
      textModelPath: textModelPath,
      vocabPath: vocabPath,
      imageModelPath: imageModelPath,
      clipTextModelPath: clipTextModelPath,
    );
  }

  /// 文本嵌入：text → BERT → Mean Pooling → L2 归一化 → 512 维向量
  ///
  /// 使用 attention mask 加权平均（mean pooling）代替 CLS 提取，
  /// 语义区分度更好（CLS 向量区分度差，不相关文本相似度常 >0.8）。
  Future<List<double>> embedText(String text) async {
    if (_disposed) throw StateError('EmbeddingEngine has been disposed');

    // 1. 分词
    final encoding = _tokenizer.encode(text);
    final inputIds = encoding.inputIdsInt64;
    final attentionMask = encoding.attentionMaskInt64;
    final tokenTypeIds = encoding.tokenTypeIdsInt64;

    // 2. 准备 ONNX 输入
    final inputs = {
      'input_ids': await OrtValue.fromList(inputIds, [1, kMaxSequenceLength]),
      'attention_mask':
          await OrtValue.fromList(attentionMask, [1, kMaxSequenceLength]),
      'token_type_ids':
          await OrtValue.fromList(tokenTypeIds, [1, kMaxSequenceLength]),
    };

    // 3. 推理
    final outputs = await _textSession.run(inputs);

    // 4. Mean pooling（attention mask 加权平均）
    final outputName = _textSession.outputNames.first;
    final rawOutput = await outputs[outputName]!.asList();
    final embedding = _meanPooling(rawOutput, attentionMask);

    // 5. L2 归一化
    return _l2Normalize(embedding);
  }

  /// 跨模态文本嵌入：text → CLIP tokenizer → MobileCLIP 文本编码器 → L2 归一化 → 512 维向量
  ///
  /// 生成的向量与 [embedImage] 的向量在同一空间，可直接计算余弦相似度。
  /// 用于文本搜索图片内容。
  Future<List<double>> embedTextForImage(String text) async {
    if (_disposed) throw StateError('EmbeddingEngine has been disposed');
    final session = _clipTextSession;
    final tokenizer = _clipTokenizer;
    if (session == null || tokenizer == null) {
      throw StateError('MobileCLIP 文本编码器未加载');
    }

    // 1. CLIP 分词
    final inputIds = tokenizer.encode(text);

    // 2. 构建 attention mask
    // encode 返回 [BOS, text..., EOS, EOS(padding)...]，第一个 EOS 之后均为 padding
    // ONNX 模型的 Equal 节点需要 attention_mask 区分真实 token 与 padding
    const eosToken = 49407;
    final firstEos = inputIds.indexOf(eosToken);
    final realLen = firstEos == -1 ? inputIds.length : firstEos + 1;
    final attentionMask = Int64List.fromList(
      List<int>.generate(inputIds.length, (i) => i < realLen ? 1 : 0),
    );

    // 3. 准备 ONNX 输入
    final inputIds64 = Int64List.fromList(inputIds);
    final inputs = <String, OrtValue>{
      'input_ids': await OrtValue.fromList(inputIds64, [1, 77]),
      'attention_mask': await OrtValue.fromList(attentionMask, [1, 77]),
    };

    // 4. 推理
    final outputs = await session.run(inputs);
    final rawOutput = await outputs.values.first.asList();
    final outputData = _flattenOutput(rawOutput);

    // 5. 提取 512 维向量
    final embedding = outputData;

    // 6. L2 归一化
    return _l2Normalize(embedding);
  }

  /// 图像嵌入：bytes → MobileCLIP → L2 归一化 → 512 维向量
  ///
  /// 解码优先级：image 包 (纯 Dart) → dart:ui ImageDescriptor (兜底)
  Future<List<double>> embedImage(Uint8List imageBytes) async {
    if (_disposed) throw StateError('EmbeddingEngine has been disposed');
    final imageSession = _imageSession;
    if (imageSession == null) {
      throw StateError('图像模型未加载（init 时未提供 imageModelPath）');
    }

    if (imageBytes.isEmpty) {
      throw ArgumentError('图像字节为空');
    }

    // 1. 解码图像（降级策略）
    img.Image? decoded = img.decodeImage(imageBytes);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      // 降级：使用 dart:ui 的 ImageDescriptor 解码
      decoded = await _decodeWithUi(imageBytes);
      if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
        throw ArgumentError(
            '无法解码图像（字节数=${imageBytes.length}，image 包和 dart:ui 均失败）');
      }
    }

    // 2. 缩放至 224×224
    final resized = img.copyResize(
      decoded,
      width: kImageSize,
      height: kImageSize,
      interpolation: img.Interpolation.linear,
    );

    // 3. 转换为 CHW 格式并归一化
    final chwData = _imageToCHW(resized);

    // 4. 准备 ONNX 输入
    final input =
        await OrtValue.fromList(chwData, [1, 3, kImageSize, kImageSize]);

    // 5. 推理
    final inputs = {'input': input};
    final outputs = await imageSession.run(inputs);

    // 6. 提取输出向量
    final rawOutput = await outputs.values.first.asList();
    final outputData = _flattenOutput(rawOutput);

    // 7. L2 归一化
    return _l2Normalize(outputData);
  }

  /// 使用 dart:ui 的 Skia 图像解码器（降级方案）
  ///
  /// image 包对 16-bit PNG、调色板 PNG、交错 PNG 等支持有限，
  /// dart:ui 通过 Skia 解码，覆盖更多格式。
  Future<img.Image?> _decodeWithUi(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      final uiImage = frameInfo.image;

      // 读取像素数据 (RGBA, premultiplied alpha)
      final byteData =
          await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;

      final rgba = byteData.buffer.asUint8List();
      final width = uiImage.width;
      final height = uiImage.height;

      // 转换为 img.Image
      final image = img.Image(width: width, height: height);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final offset = (y * width + x) * 4;
          image.setPixelRgba(
            x,
            y,
            rgba[offset],
            rgba[offset + 1],
            rgba[offset + 2],
            rgba[offset + 3],
          );
        }
      }
      return image;
    } catch (e) {
      return null;
    }
  }

  /// 延迟加载 MobileCLIP 文本编码器（用于跨模态搜索）
  ///
  /// 在应用启动时不加载，避免同时加载 3 个模型导致内存不足。
  /// 在需要跨模态搜索时调用此方法。
  Future<bool> loadClipTextEncoder(String clipTextModelPath) async {
    if (_clipTextSession != null) return true; // 已加载
    if (_disposed) throw StateError('EmbeddingEngine has been disposed');

    print(
        '🔧 [loadClipTextEncoder] 正在延迟加载 MobileCLIP 文本编码器: $clipTextModelPath');

    // 判断路径类型：asset 路径 vs 文件路径
    final isAssetPath = clipTextModelPath.startsWith('assets/');
    try {
      if (isAssetPath) {
        _clipTextSession = await _ort.createSessionFromAsset(clipTextModelPath);
      } else {
        final file = File(clipTextModelPath);
        if (!await file.exists()) {
          print('   ❌ 文件不存在: $clipTextModelPath');
          return false;
        }
        final stat = await file.stat();
        print(
            '   >>> 文件大小: ${(stat.size / 1024 / 1024).toStringAsFixed(1)} MB, '
            '修改时间: ${stat.modified}');
        _clipTextSession = await _ort.createSession(clipTextModelPath);
      }
      _clipTokenizer = await ClipTokenizer.fromAssets();
      print('   ✅ MobileCLIP 文本编码器延迟加载成功');
      return true;
    } catch (e) {
      print('   ❌ 延迟加载失败: $e');
      return false;
    }
  }

  /// MobileCLIP 文本编码器是否已加载
  bool get isClipTextEncoderLoaded => _clipTextSession != null;

  /// 释放资源
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // ONNX Runtime 的 session 不需要手动释放（由 OnnxRuntime 管理）
  }

  // ============================================================
  // 批量处理方法
  // ============================================================

  /// 批量文本嵌入
  ///
  /// [texts] 文本列表
  /// [batchSize] 并发批次大小（默认 8）
  /// [onProgress] 进度回调
  /// [continueOnError] 单个失败是否继续（默认 true）
  ///
  /// 返回 [BatchEmbedResult]，包含成功向量和失败索引
  Future<BatchEmbedResult> batchEmbedText(
    List<String> texts, {
    int batchSize = 8,
    BatchProgressCallback? onProgress,
    bool continueOnError = true,
  }) async {
    if (_disposed) throw StateError('EmbeddingEngine has been disposed');

    final embeddings = <List<double>>[];
    final failedIndices = <int>[];
    final total = texts.length;

    for (int i = 0; i < texts.length; i += batchSize) {
      final end = (i + batchSize < texts.length) ? i + batchSize : texts.length;
      final batch = texts.sublist(i, end);

      // 并行处理一个批次
      final futures = <Future<List<double>?>>[];
      for (int j = 0; j < batch.length; j++) {
        futures.add(_embedTextSafe(batch[j]));
      }

      final results = await Future.wait(futures);

      // 收集结果
      for (int j = 0; j < results.length; j++) {
        final globalIndex = i + j;
        final result = results[j];

        if (result != null) {
          embeddings.add(result);
          onProgress?.call(globalIndex + 1, total, null);
        } else {
          failedIndices.add(globalIndex);
          onProgress?.call(globalIndex + 1, total, '文本嵌入失败');

          if (!continueOnError) {
            return BatchEmbedResult(
              embeddings: embeddings,
              failedIndices: failedIndices,
            );
          }
        }
      }
    }

    return BatchEmbedResult(
      embeddings: embeddings,
      failedIndices: failedIndices,
    );
  }

  /// 批量图像嵌入
  ///
  /// [images] 图像字节列表
  /// [batchSize] 并发批次大小（默认 4，图像处理更重）
  /// [onProgress] 进度回调
  /// [continueOnError] 单个失败是否继续（默认 true）
  ///
  /// 返回 [BatchEmbedResult]，包含成功向量和失败索引
  Future<BatchEmbedResult> batchEmbedImage(
    List<Uint8List> images, {
    int batchSize = 4,
    BatchProgressCallback? onProgress,
    bool continueOnError = true,
  }) async {
    if (_disposed) throw StateError('EmbeddingEngine has been disposed');
    if (_imageSession == null) {
      throw StateError('图像模型未加载（init 时未提供 imageModelPath）');
    }

    final embeddings = <List<double>>[];
    final failedIndices = <int>[];
    final total = images.length;

    for (int i = 0; i < images.length; i += batchSize) {
      final end =
          (i + batchSize < images.length) ? i + batchSize : images.length;
      final batch = images.sublist(i, end);

      // 并行处理一个批次
      final futures = <Future<List<double>?>>[];
      for (int j = 0; j < batch.length; j++) {
        futures.add(_embedImageSafe(batch[j]));
      }

      final results = await Future.wait(futures);

      // 收集结果
      for (int j = 0; j < results.length; j++) {
        final globalIndex = i + j;
        final result = results[j];

        if (result != null) {
          embeddings.add(result);
          onProgress?.call(globalIndex + 1, total, null);
        } else {
          failedIndices.add(globalIndex);
          onProgress?.call(globalIndex + 1, total, '图像嵌入失败');

          if (!continueOnError) {
            return BatchEmbedResult(
              embeddings: embeddings,
              failedIndices: failedIndices,
            );
          }
        }
      }
    }

    return BatchEmbedResult(
      embeddings: embeddings,
      failedIndices: failedIndices,
    );
  }

  /// 安全的文本嵌入（失败返回 null 而非抛异常）
  Future<List<double>?> _embedTextSafe(String text) async {
    try {
      return await embedText(text);
    } catch (e) {
      return null;
    }
  }

  /// 安全的图像嵌入（失败返回 null 而非抛异常）
  Future<List<double>?> _embedImageSafe(Uint8List imageBytes) async {
    try {
      return await embedImage(imageBytes);
    } catch (e) {
      return null;
    }
  }

  // ============================================================
  // 内部方法
  // ============================================================

  /// 从 BERT 输出中提取 CLS 向量（768 维）
  ///
  /// BERT 输出 shape: [1, 128, 768]
  /// asList() 可能返回:
  ///   - 扁平列表（长度 98304）→ 取前 768 个值（CLS token）
  ///   - 嵌套列表 [[[...]]] → 递归取 batch[0][0] 位置的 768 维向量
  List<double> _extractClsVector(dynamic data) {
    if (data is! List) {
      throw StateError('BERT 输出不是 List: ${data.runtimeType}');
    }
    if (data.isEmpty) {
      throw StateError('BERT 输出为空');
    }

    // 情况 1: 扁平列表（元素是 num）
    if (data.first is num) {
      final flat = data.map((e) => (e as num).toDouble()).toList();
      if (flat.length >= kTextEmbeddingDim) {
        return flat.sublist(0, kTextEmbeddingDim);
      }
      return flat;
    }

    // 情况 2: 嵌套列表，递归取最内层第一个 num 列表
    // [batch][seq][hidden] → batch[0][0] = CLS 向量
    dynamic current = data;
    while (current is List && current.isNotEmpty && current.first is! num) {
      current = current.first;
    }
    if (current is List && current.isNotEmpty && current.first is num) {
      return current.map((e) => (e as num).toDouble()).toList();
    }
    throw StateError('无法解析 BERT 输出结构: ${data.runtimeType}');
  }

  /// Mean pooling：对有效 token 的输出做 attention mask 加权平均
  ///
  /// BERT 输出 shape: [1, 128, 512]
  /// 只对 attention_mask=1 的 token 做平均，忽略 padding token。
  /// 相比 CLS 提取，mean pooling 的语义区分度显著更好。
  List<double> _meanPooling(dynamic data, List<int> attentionMask) {
    if (data is! List || (data as List).isEmpty) {
      throw StateError('BERT 输出无效: ${data.runtimeType}');
    }

    // 提取 token 矩阵 [seq_len, hidden_dim]
    final tokenMatrix = _extractTokenMatrix(data);

    // 加权平均：只累加 attention_mask=1 的 token
    final pooled = List<double>.filled(kTextEmbeddingDim, 0.0);
    int validCount = 0;
    final seqLen = tokenMatrix.length < attentionMask.length
        ? tokenMatrix.length
        : attentionMask.length;
    for (int i = 0; i < seqLen; i++) {
      if (attentionMask[i] == 1) {
        validCount++;
        final tokenVec = tokenMatrix[i];
        for (int j = 0; j < kTextEmbeddingDim && j < tokenVec.length; j++) {
          pooled[j] += tokenVec[j];
        }
      }
    }
    if (validCount > 0) {
      for (int j = 0; j < kTextEmbeddingDim; j++) {
        pooled[j] /= validCount;
      }
    }
    return pooled;
  }

  /// 从 BERT ONNX 输出提取 token 矩阵 [seq_len, hidden_dim]
  ///
  /// 处理两种 asList() 返回结构：
  ///   - 扁平列表（长度 seq_len * hidden_dim）→ 按 hidden_dim 切分
  ///   - 嵌套列表 [[[...]]]（[1, seq, hidden]）→ 取 batch[0]
  List<List<double>> _extractTokenMatrix(dynamic data) {
    if (data is! List || data.isEmpty) {
      throw StateError('BERT 输出无效: ${data.runtimeType}');
    }

    // 情况 1: 扁平列表（元素是 num）
    if (data.first is num) {
      final flat = data.map((e) => (e as num).toDouble()).toList();
      final seqLen = flat.length ~/ kTextEmbeddingDim;
      return List.generate(
        seqLen,
        (i) => flat.sublist(i * kTextEmbeddingDim, (i + 1) * kTextEmbeddingDim),
      );
    }

    // 情况 2: 嵌套列表，递归到 [seq, hidden] 层级
    dynamic current = data;
    while (current is List &&
        current.isNotEmpty &&
        current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is! num) {
      current = current.first;
    }

    if (current is List &&
        current.isNotEmpty &&
        current.first is List &&
        (current.first as List).isNotEmpty &&
        (current.first as List).first is num) {
      return current.map<List<double>>((token) {
        return (token as List).map((e) => (e as num).toDouble()).toList();
      }).toList();
    }

    throw StateError('无法解析 BERT token 矩阵: ${data.runtimeType}');
  }

  /// 将 MobileCLIP 输出（可能嵌套 [1, 512]）扁平化为 List<double>
  List<double> _flattenOutput(dynamic data) {
    if (data is! List) {
      throw StateError('输出不是 List: ${data.runtimeType}');
    }
    if (data.isEmpty) {
      throw StateError('输出为空');
    }

    // 扁平列表
    if (data.first is num) {
      return data.map((e) => (e as num).toDouble()).toList();
    }

    // 嵌套列表，递归扁平化
    final result = <double>[];
    void flatten(List list) {
      for (final e in list) {
        if (e is num) {
          result.add(e.toDouble());
        } else if (e is List) {
          flatten(e);
        }
      }
    }

    flatten(data);
    return result;
  }

  /// L2 归一化
  List<double> _l2Normalize(List<double> vector) {
    double norm = 0;
    for (final v in vector) {
      norm += v * v;
    }
    norm = sqrt(norm);
    if (norm < 1e-12) {
      // 零向量，返回原向量
      return List<double>.from(vector);
    }
    return vector.map((v) => v / norm).toList();
  }

  /// 图像 → CHW 格式 + 归一化
  List<double> _imageToCHW(img.Image image) {
    final data = List<double>.filled(3 * kImageSize * kImageSize, 0.0);
    final width = image.width;
    final height = image.height;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final pixel = image.getPixel(x, y);
        final r = pixel.r.toDouble() / 255.0;
        final g = pixel.g.toDouble() / 255.0;
        final b = pixel.b.toDouble() / 255.0;

        // CHW 布局: channel * (H*W) + y * W + x
        final offsetR = 0 * height * width + y * width + x;
        final offsetG = 1 * height * width + y * width + x;
        final offsetB = 2 * height * width + y * width + x;

        data[offsetR] = (r - _imageMean[0]) / _imageStd[0];
        data[offsetG] = (g - _imageMean[1]) / _imageStd[1];
        data[offsetB] = (b - _imageMean[2]) / _imageStd[2];
      }
    }

    return data;
  }
}
