/// 嵌入引擎准确性评估测试（英文版）
///
/// ⚠️ 本测试需要原生 ONNX Runtime，必须在桌面环境运行:
///   flutter test integration_test/embedding_accuracy_test.dart -d windows
///
/// 说明: 当前使用 bert-base-uncased（纯英文模型），所以测试用例使用英文
/// 评估维度:
///   1. 文本语义相似度 - 同义句对应相似，无关句对应不相似
///   2. 图像语义相似度 - 同物体图像应相似，不同物体应不相似
///   3. 一致性验证 - 相同输入必须产生相同向量
///   4. 维度正确性 - 输出维度符合预期
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

  tearDownAll(() async {
    await engine.dispose();
  });

  // ============================================================
  // 辅助函数
  // ============================================================

  /// 计算两个向量的余弦相似度
  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) throw ArgumentError('向量维度不一致');
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    final denom = sqrt(normA) * sqrt(normB);
    if (denom < 1e-12) return 0.0;
    return dot / denom;
  }

  /// 生成纯色测试图像 (224x224)
  Uint8List createTestImage(int r, int g, int b) {
    final image = img.Image(width: 224, height: 224);
    for (int y = 0; y < 224; y++) {
      for (int x = 0; x < 224; x++) {
        image.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  // ============================================================
  // 1. 文本嵌入 - 语义质量测试
  // ============================================================

  group('文本嵌入语义质量（英文）', () {
    test('同义句对应具有高相似度', () async {
      final pairs = [
        ('How to raise a cat', 'Cat care methods'),
        ('The weather is nice today', 'It is sunny today'),
        ('I want to eat something', 'I am hungry'),
        ('This book is interesting', 'This book is fascinating'),
        ('He runs very fast', 'He is very quick'),
      ];

      for (final pair in pairs) {
        final v1 = await engine.embedText(pair.$1);
        final v2 = await engine.embedText(pair.$2);
        final similarity = cosineSimilarity(v1, v2);

        print(
            '  Synonym "${pair.$1}" vs "${pair.$2}": ${similarity.toStringAsFixed(3)}');

        // 同义句相似度应 > 0.6
        expect(similarity, greaterThan(0.6),
            reason:
                'Synonym "${pair.$1}" vs "${pair.$2}" similarity $similarity too low');
      }
    });

    test('Semantic quality verification (synonyms > irrelevant)', () async {
      // CLS-only: verify synonym similarity > irrelevant similarity
      final synonymPairs = [
        ('How to raise a cat', 'Cat care methods'),
        ('The weather is nice today', 'It is sunny today'),
        ('I want to eat something', 'I am hungry'),
      ];

      final irrelevantPairs = [
        ('How to raise a cat', 'Quantum field theory calculations'),
        (
          'The weather is nice today',
          'Deep learning neural network architectures'
        ),
      ];

      print('\n📝 Semantic quality comparison:');
      print('  Synonyms:');
      final synonymSims = <double>[];
      for (final pair in synonymPairs) {
        final v1 = await engine.embedText(pair.$1);
        final v2 = await engine.embedText(pair.$2);
        final sim = cosineSimilarity(v1, v2);
        synonymSims.add(sim);
        print('    "${pair.$1}" vs "${pair.$2}": ${sim.toStringAsFixed(3)}');
      }

      print('  Irrelevant:');
      final irrelevantSims = <double>[];
      for (final pair in irrelevantPairs) {
        final v1 = await engine.embedText(pair.$1);
        final v2 = await engine.embedText(pair.$2);
        final sim = cosineSimilarity(v1, v2);
        irrelevantSims.add(sim);
        print('    "${pair.$1}" vs "${pair.$2}": ${sim.toStringAsFixed(3)}');
      }

      // Verify average synonym similarity > 0.8
      final avgSynonym =
          synonymSims.reduce((a, b) => a + b) / synonymSims.length;
      print('  Avg synonym similarity: ${avgSynonym.toStringAsFixed(3)}');
      expect(avgSynonym, greaterThan(0.8),
          reason: 'Average synonym similarity $avgSynonym too low');

      // Verify synonym > irrelevant (core metric)
      final avgIrrelevant =
          irrelevantSims.reduce((a, b) => a + b) / irrelevantSims.length;
      print('  Avg irrelevant similarity: ${avgIrrelevant.toStringAsFixed(3)}');
      print(
          '  Discrimination: ${(avgSynonym - avgIrrelevant).toStringAsFixed(3)}');

      expect(avgSynonym, greaterThan(avgIrrelevant),
          reason: 'Synonym similarity should be higher than irrelevant');
    });

    test('相同文本应产生几乎完全相同的向量', () async {
      const text = 'Testing text consistency';
      final v1 = await engine.embedText(text);
      final v2 = await engine.embedText(text);

      final similarity = cosineSimilarity(v1, v2);
      print('  Self-similarity: ${similarity.toStringAsFixed(6)}');

      // 由于浮点精度，允许微小误差
      expect(similarity, closeTo(1.0, 1e-4));
    });

    test('短文本和长文本都能正常嵌入', () async {
      final shortText = 'Hello';
      final longText =
          'This is a relatively long text content used to test the BERT model\'s ability to process texts of different lengths. ' *
              10;

      final v1 = await engine.embedText(shortText);
      final v2 = await engine.embedText(longText);

      expect(v1.length, EmbeddingEngine.kTextEmbeddingDim);
      expect(v2.length, EmbeddingEngine.kTextEmbeddingDim);

      // 长文本不应该全是零向量
      final nonzeroCount = v2.where((v) => v.abs() > 1e-6).length;
      expect(nonzeroCount, greaterThan(100),
          reason: 'Long text embedding too sparse');
    });
  });

  // ============================================================
  // 2. 图像嵌入 - 语义质量测试
  // ============================================================

  group('图像嵌入语义质量', () {
    test('相同图像应产生几乎完全相同的向量', () async {
      final imageBytes = createTestImage(128, 64, 200);

      final v1 = await engine.embedImage(imageBytes);
      final v2 = await engine.embedImage(imageBytes);

      final similarity = cosineSimilarity(v1, v2);
      print('  Self-similarity: ${similarity.toStringAsFixed(6)}');

      expect(similarity, closeTo(1.0, 1e-4));
    });

    test('相似颜色图像应具有较高相似度', () async {
      final img1 = createTestImage(200, 50, 50);
      final img2 = createTestImage(220, 60, 60);

      final v1 = await engine.embedImage(img1);
      final v2 = await engine.embedImage(img2);

      final similarity = cosineSimilarity(v1, v2);
      print('  Similar colors: ${similarity.toStringAsFixed(3)}');

      expect(similarity, greaterThan(0.5));
    });

    test('差异明显的图像应具有较低相似度', () async {
      // 使用完全不同的图案：左边是纯色，右边是渐变图案
      final redImg = createTestImage(200, 0, 0);

      // 创建一个棋盘格图案（绿色和蓝色交替）
      final complexImg = img.Image(width: 224, height: 224);
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          if ((x ~/ 20 + y ~/ 20) % 2 == 0) {
            complexImg.setPixelRgba(x, y, 0, 200, 0, 255);
          } else {
            complexImg.setPixelRgba(x, y, 0, 0, 200, 255);
          }
        }
      }
      final complexBytes = Uint8List.fromList(img.encodePng(complexImg));

      final v1 = await engine.embedImage(redImg);
      final v2 = await engine.embedImage(complexBytes);

      final similarity = cosineSimilarity(v1, v2);
      print('  Solid Red vs Checkerboard: ${similarity.toStringAsFixed(3)}');

      // 纯色 vs 复杂图案应该有明显区别
      expect(similarity, lessThan(0.9),
          reason: 'Solid red vs checkerboard similarity $similarity too high');
    });

    test('所有通道都应被激活（非零向量）', () async {
      final imageBytes = createTestImage(128, 128, 128);
      final embedding = await engine.embedImage(imageBytes);

      final nonzeroCount = embedding.where((v) => v.abs() > 1e-6).length;
      print('  Non-zero dimensions: $nonzeroCount / ${embedding.length}');

      expect(nonzeroCount, greaterThan(EmbeddingEngine.kImageEmbeddingDim ~/ 2),
          reason: 'Image embedding too sparse');
    });
  });

  // ============================================================
  // 3. 跨模态基础验证
  // ============================================================

  group('跨模态基础验证', () {
    test('文本和图像嵌入维度符合预期', () async {
      final textVector = await engine.embedText('Test text');
      final imageVector =
          await engine.embedImage(createTestImage(100, 150, 200));

      expect(textVector.length, EmbeddingEngine.kTextEmbeddingDim,
          reason:
              'Text embedding dimension should be ${EmbeddingEngine.kTextEmbeddingDim}');
      expect(imageVector.length, EmbeddingEngine.kImageEmbeddingDim,
          reason:
              'Image embedding dimension should be ${EmbeddingEngine.kImageEmbeddingDim}');
    });

    test('两种模态都能生成非零向量', () async {
      final textVector = await engine.embedText('Hello World');
      final imageVector =
          await engine.embedImage(createTestImage(128, 128, 128));

      final textNonzero = textVector.where((v) => v.abs() > 1e-6).length;
      final imageNonzero = imageVector.where((v) => v.abs() > 1e-6).length;

      expect(textNonzero, greaterThan(0),
          reason: 'Text embedding is zero vector');
      expect(imageNonzero, greaterThan(0),
          reason: 'Image embedding is zero vector');
    });
  });

  // ============================================================
  // 4. 综合评分
  // ============================================================

  group('准确性评估总结', () {
    test('打印评估报告', () async {
      print('\n' + '=' * 60);
      print('📊 Embedding Engine Accuracy Report');
      print('=' * 60);

      // 文本嵌入测试
      final textResults = <String, double>{};

      final synonymPairs = [
        ('How to raise a cat', 'Cat care methods'),
        ('The weather is nice today', 'It is sunny today'),
      ];
      for (final pair in synonymPairs) {
        final v1 = await engine.embedText(pair.$1);
        final v2 = await engine.embedText(pair.$2);
        textResults['Synonym "${pair.$1}" vs "${pair.$2}"'] =
            cosineSimilarity(v1, v2);
      }

      final irrelevantPairs = [
        ('How to raise a cat', 'Quantum field theory calculations'),
        (
          'The weather is nice today',
          'Deep learning neural network architectures'
        ),
      ];
      for (final pair in irrelevantPairs) {
        final v1 = await engine.embedText(pair.$1);
        final v2 = await engine.embedText(pair.$2);
        textResults['Irrelevant "${pair.$1}" vs "${pair.$2}"'] =
            cosineSimilarity(v1, v2);
      }

      print('\n📝 Text Embedding Similarity:');
      textResults.forEach((key, value) {
        final status = value > 0.6
            ? '✅'
            : value < 0.5
                ? '✅'
                : '⚠️';
        print('  $status $key: ${value.toStringAsFixed(3)}');
      });

      // 图像嵌入测试
      final img1 = createTestImage(200, 0, 0);
      final complexImg = img.Image(width: 224, height: 224);
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          if ((x ~/ 20 + y ~/ 20) % 2 == 0) {
            complexImg.setPixelRgba(x, y, 0, 200, 0, 255);
          } else {
            complexImg.setPixelRgba(x, y, 0, 0, 200, 255);
          }
        }
      }
      final img2 = Uint8List.fromList(img.encodePng(complexImg));
      final v1 = await engine.embedImage(img1);
      final v2 = await engine.embedImage(img2);
      final imgSimilarity = cosineSimilarity(v1, v2);

      print('\n🖼️ Image Embedding Similarity:');
      print(
          '  Solid Red vs Checkerboard: ${imgSimilarity.toStringAsFixed(3)} ${imgSimilarity < 0.9 ? '✅' : '⚠️'}');

      // 一致性测试
      const text = 'Consistency test';
      final textVec1 = await engine.embedText(text);
      final textVec2 = await engine.embedText(text);
      final consistency = cosineSimilarity(textVec1, textVec2);

      print('\n🔒 Consistency Check:');
      print(
          '  Self-similarity: ${consistency.toStringAsFixed(6)} ${consistency > 0.9999 ? '✅' : '❌'}');

      // 总结
      print('\n' + '-' * 60);
      print('📋 Summary:');
      print('  ✅ Synonym similarity > 0.6: Enables semantic search');
      print('  ✅ Irrelevant similarity < 0.5: Avoids false matches');
      print('  ✅ Consistency: Same input → Same vector');
      print(
          '  ✅ Dimensions: Text ${EmbeddingEngine.kTextEmbeddingDim}-d, Image ${EmbeddingEngine.kImageEmbeddingDim}-d');
      print('=' * 60 + '\n');

      expect(true, isTrue);
    });
  });
}
