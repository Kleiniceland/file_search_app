/// EmbeddingEngine 集成测试
///
/// ⚠️ 本测试需要原生 ONNX Runtime，必须在桌面环境运行:
///   flutter test integration_test/embedding_engine_test.dart -d windows
///
/// 测试点:
///   1. 引擎初始化（模型加载 + 分词器加载）
///   2. 文本嵌入（分词 → BERT → 归一化）
///   3. 图像嵌入（MobileCLIP 导出后启用）
///   4. L2 归一化正确性
///   5. 向量维度验证
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;
import 'package:file_search_app/services/embedding_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late EmbeddingEngine engine;

  setUpAll(() async {
    final projectRoot = Directory.current.path;
    engine = await EmbeddingEngine.init(
      imageModelPath:
          '$projectRoot/assets/models/mobileclip_onnx/image_encoder.onnx',
    );
  });

  group('EmbeddingEngine', () {
    test('文本嵌入：返回正确维度', () async {
      final embedding = await engine.embedText('Hello world');
      expect(embedding.length, EmbeddingEngine.kTextEmbeddingDim);
    });

    test('文本嵌入：L2 归一化验证', () async {
      final embedding = await engine.embedText('测试文本嵌入');
      double norm = 0;
      for (final v in embedding) {
        norm += v * v;
      }
      expect(sqrt(norm), closeTo(1.0, 1e-4));
    });

    test('文本嵌入：相同文本得到相同向量', () async {
      final v1 = await engine.embedText('Hello world');
      final v2 = await engine.embedText('Hello world');
      for (int i = 0; i < v1.length; i++) {
        expect(v1[i], closeTo(v2[i], 1e-6));
      }
    });

    test('文本嵌入：不同文本得到不同向量', () async {
      final v1 = await engine.embedText('Hello world');
      final v2 = await engine.embedText('Goodbye world');
      double dot = 0;
      for (int i = 0; i < v1.length; i++) {
        dot += v1[i] * v2[i];
      }
      // "Hello" 和 "Goodbye" 语义接近（都是问候语），相似度会比较高
      // 但不应该完全相同
      expect(dot, lessThan(0.999));
    });

    test('文本嵌入：中文支持', () async {
      final embedding = await engine.embedText('你好世界');
      expect(embedding.length, EmbeddingEngine.kTextEmbeddingDim);
      final nonzero = embedding.where((v) => v.abs() > 1e-6).length;
      expect(nonzero, greaterThan(0));
    });

    test('图像嵌入：返回正确维度', () async {
      final image = img.Image(width: 224, height: 224);
      final bytes = img.encodePng(image);
      final embedding = await engine.embedImage(Uint8List.fromList(bytes));
      expect(embedding.length, EmbeddingEngine.kImageEmbeddingDim);
    });

    test('图像嵌入：L2 归一化验证', () async {
      final image = img.Image(width: 224, height: 224);
      final bytes = img.encodePng(image);
      final embedding = await engine.embedImage(Uint8List.fromList(bytes));
      double norm = 0;
      for (final v in embedding) {
        norm += v * v;
      }
      expect(sqrt(norm), closeTo(1.0, 1e-4));
    });

    test('图像嵌入：相同图像得到相同向量', () async {
      final image = img.Image(width: 224, height: 224);
      final bytes = img.encodePng(image);
      final v1 = await engine.embedImage(Uint8List.fromList(bytes));
      final v2 = await engine.embedImage(Uint8List.fromList(bytes));
      for (int i = 0; i < v1.length; i++) {
        expect(v1[i], closeTo(v2[i], 1e-6));
      }
    });

    test('dispose 后调用抛异常', () async {
      await engine.dispose();
      expect(
        () => engine.embedText('test'),
        throwsStateError,
      );
    });
  });

  group('EmbeddingEngine 批量处理', () {
    late EmbeddingEngine batchEngine;

    setUpAll(() async {
      batchEngine = await EmbeddingEngine.init(
        imageModelPath:
            'C:/project/file_search_app/assets/models/mobileclip_onnx/image_encoder.onnx',
      );
    });

    tearDownAll(() async {
      await batchEngine.dispose();
    });

    test('批量文本嵌入：返回正确数量', () async {
      final texts = ['Hello', 'World', 'Test', 'Batch'];
      final result = await batchEngine.batchEmbedText(texts, batchSize: 2);

      expect(result.successCount, 4);
      expect(result.failureCount, 0);
    });

    test('批量文本嵌入：所有向量维度正确', () async {
      final texts = ['Hello', 'World'];
      final result = await batchEngine.batchEmbedText(texts);

      for (final embedding in result.embeddings) {
        expect(embedding.length, EmbeddingEngine.kTextEmbeddingDim);
      }
    });

    test('批量文本嵌入：进度回调被调用', () async {
      final texts = ['A', 'B', 'C'];
      final progressCalls = <int>[];

      await batchEngine.batchEmbedText(
        texts,
        onProgress: (current, total, error) {
          progressCalls.add(current);
        },
      );

      expect(progressCalls, containsAll([1, 2, 3]));
    });

    test('批量图像嵌入：返回正确数量', () async {
      final images = <Uint8List>[];
      for (int i = 0; i < 3; i++) {
        final image = img.Image(width: 224, height: 224);
        images.add(Uint8List.fromList(img.encodePng(image)));
      }

      final result = await batchEngine.batchEmbedImage(images, batchSize: 2);

      expect(result.successCount, 3);
      expect(result.failureCount, 0);
    });

    test('批量图像嵌入：所有向量维度正确', () async {
      final image = img.Image(width: 224, height: 224);
      final bytes = Uint8List.fromList(img.encodePng(image));

      final result = await batchEngine.batchEmbedImage([bytes, bytes]);

      for (final embedding in result.embeddings) {
        expect(embedding.length, EmbeddingEngine.kImageEmbeddingDim);
      }
    });

    test('批量处理：空列表返回空结果', () async {
      final textResult = await batchEngine.batchEmbedText([]);
      expect(textResult.successCount, 0);
      expect(textResult.failureCount, 0);

      final imageResult = await batchEngine.batchEmbedImage([]);
      expect(imageResult.successCount, 0);
      expect(imageResult.failureCount, 0);
    });
  });
}
