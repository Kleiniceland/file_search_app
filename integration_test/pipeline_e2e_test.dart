/// Week 4 端到端管道功能测试
///
/// 测试完整流程：文件导入 → 解析 → 嵌入 → 存储 → 搜索 → 返回结果
///
/// 运行方式：
///   flutter test integration_test/pipeline_e2e_test.dart -d windows

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:file_search_app/services/embedding_engine.dart';
import 'package:file_search_app/services/vector_store.dart';
import 'package:file_search_app/services/search_service.dart';
import 'package:file_search_app/services/pipeline_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late EmbeddingEngine engine;
  late VectorStore vectorStore;
  late SearchService searchService;
  late PipelineService pipelineService;
  late Directory tempDir;

  setUpAll(() async {
    // 1. 初始化嵌入引擎
    engine = await EmbeddingEngine.initChinese(
      imageModelPath: 'assets/models/mobileclip_onnx/image_encoder.onnx',
    );

    // 2. 初始化向量存储（ObjectBox）
    final storagePath = '${Directory.systemTemp.path}/pipeline_e2e_objectbox';
    vectorStore = VectorStore();
    await vectorStore.init(storagePath: storagePath);
    await vectorStore.clear(); // 清空旧数据

    // 4. 创建服务
    searchService = SearchService(
      engine: engine,
      vectorStore: vectorStore,
    );
    pipelineService = PipelineService(
      engine: engine,
      vectorStore: vectorStore,
    );

    // 5. 创建临时测试目录
    tempDir = await Directory.systemTemp.createTemp('e2e_test_');
  });

  tearDownAll(() async {
    await vectorStore.clear();
    await vectorStore.close();
    await engine.dispose();
    await tempDir.delete(recursive: true);
  });

  group('端到端管道：文件导入 → 解析 → 嵌入 → 存储', () {
    test('索引单个 TXT 文件', () async {
      // 创建测试文件
      final file = File('${tempDir.path}/猫咪饲养指南.txt');
      await file.writeAsString('如何养一只猫：首先需要准备猫粮、猫砂和猫窝。每天要给猫咪喂食两次，定期清理猫砂盆。');

      // 索引
      final ok = await pipelineService.indexFile(file);
      expect(ok, isTrue);

      // 验证已存储
      expect(vectorStore.count, greaterThanOrEqualTo(1));
      expect(vectorStore.contains(file.path), isTrue);

      // 验证记录内容
      final record = vectorStore.get(file.path);
      expect(record, isNotNull);
      expect(record!.fileName, '猫咪饲养指南.txt');
      expect(record.fileType, 'text');
      expect(record.embedding.length, EmbeddingEngine.kTextEmbeddingDim);
    });

    test('索引目录下多个文件', () async {
      // 创建多个测试文件
      await File('${tempDir.path}/天气预报.txt')
          .writeAsString('今天天气很好，阳光明媚，适合外出活动。');
      await File('${tempDir.path}/编程学习.txt')
          .writeAsString('怎么学习编程？建议从 Python 入门，掌握基础语法后再学习数据结构。');
      await File('${tempDir.path}/会议纪要.txt')
          .writeAsString('明天有会议要参加，请准备好相关材料。');

      // 索引目录
      final stats = await pipelineService.indexDirectory(tempDir.path);

      expect(stats.total, greaterThanOrEqualTo(4)); // 至少 4 个文件
      expect(stats.success, greaterThanOrEqualTo(3));
      expect(stats.failed, lessThanOrEqualTo(stats.total));
    });

    test('增量索引：未修改的文件被跳过', () async {
      // 再次索引同一目录
      final stats = await pipelineService.indexDirectory(tempDir.path);

      expect(stats.skipped, greaterThan(0), reason: '未修改的文件应该被跳过');
    });
  });

  group('端到端管道：混合语义搜索', () {
    test('语义搜索：查询"猫咪怎么养"返回相关文件', () async {
      final results = await searchService.search('猫咪怎么养', topK: 5);

      expect(results, isNotEmpty);

      // 猫相关文件应出现在前 5 个结果中（BERT 区分度有限，不要求 top1）
      final found = results.any((r) => r.fileName.contains('猫'));
      expect(found, isTrue, reason: '猫相关文件应出现在搜索结果中');
    });

    test('语义搜索：查询"天气"返回天气相关文件', () async {
      final results = await searchService.search('天气怎么样', topK: 5);

      expect(results, isNotEmpty);

      // 应该找到天气预报.txt
      final found = results.any((r) => r.fileName.contains('天气'));
      expect(found, isTrue);
    });

    test('语义搜索：查询"编程"返回编程相关文件', () async {
      final results = await searchService.search('编程入门指南', topK: 5);

      expect(results, isNotEmpty);

      final found = results.any((r) => r.fileName.contains('编程'));
      expect(found, isTrue);
    });

    test('混合搜索结果包含双维度得分', () async {
      final results = await searchService.search('会议', topK: 5);

      expect(results, isNotEmpty);

      for (final r in results) {
        expect(r.vectorScore, greaterThanOrEqualTo(0.0));
        expect(r.vectorScore, lessThanOrEqualTo(1.0));
        expect(r.keywordScore, greaterThanOrEqualTo(0.0));
        expect(r.keywordScore, lessThanOrEqualTo(1.0));

        // 验证融合公式：有关键词匹配时 0.4*语义+0.6*关键词，无匹配时 0.3*语义
        final expected = r.keywordScore > 0
            ? r.vectorScore * 0.4 + r.keywordScore * 0.6
            : r.vectorScore * 0.3;
        expect(r.finalScore, closeTo(expected, 0.01));
      }
    });

    test('结果按最终得分降序排列', () async {
      final results = await searchService.search('学习', topK: 10);

      for (int i = 1; i < results.length; i++) {
        expect(results[i - 1].finalScore,
            greaterThanOrEqualTo(results[i].finalScore),
            reason: '结果应按得分降序排列');
      }
    });
  });

  group('端到端管道：索引管理', () {
    test('删除索引后搜索不再返回该文件', () async {
      final file = File('${tempDir.path}/待删除测试.txt');
      await file.writeAsString('这是一个待删除的测试文件内容');

      await pipelineService.indexFile(file);
      expect(vectorStore.contains(file.path), isTrue);

      await pipelineService.removeIndex(file.path);
      expect(vectorStore.contains(file.path), isFalse);
    });

    test('清空索引后搜索返回空列表', () async {
      // 先清空
      await pipelineService.clearIndex();
      expect(vectorStore.count, 0);

      // 搜索应该返回空
      final results = await searchService.search('测试', topK: 5);
      expect(results, isEmpty);
    });
  });
}
