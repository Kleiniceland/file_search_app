/// 检索准确性基准测试
///
/// 使用预定义的测试数据集和 ground truth，
/// 评估混合检索管道的 Precision@K、Recall@K、MRR 指标。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:file_search_app/services/embedding_engine.dart';
import 'package:file_search_app/services/vector_store.dart';
import 'package:file_search_app/services/search_service.dart';
import 'package:file_search_app/services/pipeline_service.dart';

/// 测试文档定义
class TestDoc {
  final String name;
  final String content;
  final Set<String> tags; // 主题标签，用于 ground truth 匹配

  TestDoc(this.name, this.content, this.tags);
}

/// 测试查询定义
class TestQuery {
  final String query;
  final Set<String> expectedTags; // 预期匹配的文档标签

  TestQuery(this.query, this.expectedTags);
}

void main() {
  late EmbeddingEngine engine;
  late VectorStore vectorStore;
  late SearchService searchService;
  late PipelineService pipelineService;

  /// 测试数据集：10 个文档，覆盖 5 个主题
  final testDocs = [
    TestDoc('cat_care.txt', '''
猫咪饲养指南
猫咪是非常好的伴侣动物。养猫需要注意以下几点：
1. 饮食：选择优质猫粮，保证营养均衡
2. 卫生：定期清理猫砂盆，保持环境清洁
3. 健康：按时接种疫苗，定期体检
4. 运动：提供猫爬架和玩具，保持适量运动
''', {'cat', 'pet'}),
    TestDoc('cat_food.txt', '''
猫粮选择建议
不同年龄段的猫需要不同的营养配比：
- 幼猫：高蛋白、高脂肪
- 成猫：均衡营养，控制热量
- 老年猫：低脂肪、易消化
建议选择天然粮，避免含有害添加剂的产品。
''', {'cat', 'pet', 'food'}),
    TestDoc('weather_intro.txt', '''
天气与气候基础知识
天气是指大气在短时间内的状态变化，包括温度、湿度、降水、风向等要素。
气候则是某地区长期的天气平均状态。
了解天气变化对农业、交通和日常生活都有重要意义。
''', {'weather'}),
    TestDoc('weather_forecast.txt', '''
天气预报的制作方法
天气预报通过气象卫星、雷达和地面观测站收集数据，
利用数值模型进行预测。短期预报准确率较高，
长期预报存在较大不确定性。现代天气预报已经可以
精确到小时级别。
''', {'weather'}),
    TestDoc('programming_python.txt', '''
Python编程入门
Python是一种简单易学的编程语言，适合初学者。
它支持面向对象、函数式编程等多种编程范式。
Python广泛应用于数据分析、人工智能、Web开发等领域。
学习Python建议从基础语法开始，逐步掌握常用库和框架。
''', {'programming'}),
    TestDoc('programming_java.txt', '''
Java程序设计指南
Java是一种面向对象的编程语言，具有跨平台特性。
Java广泛应用于企业级开发、Android应用和大型系统。
学习Java需要掌握类、继承、多态等核心概念，
以及Spring、MyBatis等主流框架。
''', {'programming'}),
    TestDoc('meeting_notes.txt', '''
项目周会纪要
会议时间：2026年8月4日
参会人员：全体开发团队成员
议题：
1. 本周开发进度回顾
2. 下周任务分配
3. 技术难点讨论
4. 测试计划安排
''', {'meeting'}),
    TestDoc('meeting_room.txt', '''
会议室预订规则
1. 会议室需提前一天预订
2. 每次会议不超过2小时
3. 预订后如需取消，请提前通知
4. 保持会议室整洁，会后恢复桌椅
''', {'meeting'}),
    TestDoc('phone_battery.txt', '''
手机电池保养方法
1. 避免过度充电和过度放电
2. 使用原装充电器
3. 避免在高温环境下使用
4. 定期校准电池
5. 关闭不常用的后台应用以延长续航
''', {'phone', 'battery'}),
    TestDoc('phone_review.txt', '''
2026年手机推荐
今年值得购买的手机推荐：
1. 旗舰机：性能强、拍照好，适合重度用户
2. 中端机：性价比高，满足日常需求
3. 入门机：价格实惠，适合轻度使用
购买手机时需考虑预算、使用需求和品牌偏好。
''', {'phone', 'review'}),
  ];

  /// 测试查询及预期结果（通过标签匹配）
  final testQueries = [
    TestQuery('猫咪怎么养', {'cat', 'pet'}),
    TestQuery('猫粮推荐', {'cat', 'food'}),
    TestQuery('今天天气怎么样', {'weather'}),
    TestQuery('天气预报准确吗', {'weather'}),
    TestQuery('怎么学习编程', {'programming'}),
    TestQuery('Python入门', {'programming'}),
    TestQuery('会议纪要', {'meeting'}),
    TestQuery('会议室预订', {'meeting'}),
    TestQuery('手机续航差怎么办', {'phone', 'battery'}),
    TestQuery('手机推荐', {'phone', 'review'}),
    // 语义查询（不包含关键词，测试纯语义能力）
    TestQuery('小动物喂食', {'cat', 'pet', 'food'}),
    TestQuery('气象预测', {'weather'}),
  ];

  setUpAll(() async {
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();

    // 加载 BERT 中文模型
    engine = await EmbeddingEngine.initChinese();

    // 初始化向量存储（ObjectBox）
    final storagePath = '${Directory.systemTemp.path}/benchmark_objectbox';
    vectorStore = VectorStore();
    await vectorStore.init(storagePath: storagePath);
    await vectorStore.clear();

    // 创建服务
    searchService = SearchService(
      engine: engine,
      vectorStore: vectorStore,
    );
    pipelineService = PipelineService(
      engine: engine,
      vectorStore: vectorStore,
    );

    // 创建临时目录并写入测试文件
    final tempDir = Directory.systemTemp.createTempSync('benchmark_');
    for (final doc in testDocs) {
      final file = File(p.join(tempDir.path, doc.name));
      file.writeAsStringSync(doc.content);
    }

    // 索引所有测试文件
    await pipelineService.indexDirectory(tempDir.path);
  });

  tearDownAll(() async {
    await vectorStore.clear();
    await vectorStore.close();
    engine.dispose();
  });

  test('检索准确性基准测试', () async {
    // 指标累计
    final precisionAt5 = <double>[];
    final recallAt5 = <double>[];
    final mrrValues = <double>[];

    // 每个查询的详细结果
    final queryResults = <String, List<String>>{};

    for (final tq in testQueries) {
      final results = await searchService.search(tq.query, topK: 5);

      // 获取结果对应的文档标签
      final resultTags = <Set<String>>[];
      for (final r in results) {
        // 通过文件名匹配回测试文档
        final doc = testDocs.where((d) => d.name == r.fileName).firstOrNull;
        resultTags.add(doc?.tags ?? {});
      }

      // 判断每个结果是否相关（标签有交集）
      final relevantFlags = resultTags
          .map((tags) => tags.intersection(tq.expectedTags).isNotEmpty)
          .toList();

      // 记录结果文件名
      queryResults[tq.query] = results.map((r) => r.fileName).toList();

      // Precision@5
      final relevantCount = relevantFlags.take(5).where((f) => f).length;
      precisionAt5.add(relevantCount / 5);

      // Recall@5: 预期相关文档总数中，有多少出现在 top5
      final totalRelevant = testDocs
          .where((d) => d.tags.intersection(tq.expectedTags).isNotEmpty)
          .length;
      final recall = totalRelevant > 0 ? relevantCount / totalRelevant : 0.0;
      recallAt5.add(recall);

      // MRR: 第一个相关结果的排名倒数
      int firstRelevantRank = 0;
      for (int i = 0; i < relevantFlags.length; i++) {
        if (relevantFlags[i]) {
          firstRelevantRank = i + 1;
          break;
        }
      }
      mrrValues.add(firstRelevantRank > 0 ? 1.0 / firstRelevantRank : 0.0);
    }

    // 计算平均值
    final avgPrecision =
        precisionAt5.reduce((a, b) => a + b) / precisionAt5.length;
    final avgRecall = recallAt5.reduce((a, b) => a + b) / recallAt5.length;
    final mrr = mrrValues.reduce((a, b) => a + b) / mrrValues.length;
    final f1 = avgPrecision + avgRecall > 0
        ? 2 * avgPrecision * avgRecall / (avgPrecision + avgRecall)
        : 0.0;

    // 打印详细报告
    print('\n${'=' * 70}');
    print('              检索准确性基准测试报告');
    print('${'=' * 70}');
    print('测试数据集：${testDocs.length} 个文档，覆盖 5 个主题');
    final semanticCount =
        testQueries.where((q) => !RegExp(r'[a-zA-Z]').hasMatch(q.query)).length;
    print('测试查询：${testQueries.length} 个（含 $semanticCount 个纯语义查询）');
    print('检索方式：混合检索（关键词优先 + 语义辅助）');
    print('${'-' * 70}');
    print('\n查询级详细结果：');
    print('${'-' * 70}');

    for (int i = 0; i < testQueries.length; i++) {
      final tq = testQueries[i];
      final p = precisionAt5[i];
      final r = recallAt5[i];
      final rr = mrrValues[i];
      final results = queryResults[tq.query] ?? [];

      print('\n[${i + 1}] 查询: "${tq.query}"');
      print('    预期标签: ${tq.expectedTags}');
      print('    Top5 结果: ${results.isEmpty ? "无结果" : results.join(", ")}');
      print(
          '    P@5=${p.toStringAsFixed(2)}  R@5=${r.toStringAsFixed(2)}  RR=${rr.toStringAsFixed(2)}');
    }

    print('\n${'-' * 70}');
    print('汇总指标：');
    print('  ┌─────────────────────────────────────┐');
    print(
        '  │ Precision@5    : ${avgPrecision.toStringAsFixed(4).padLeft(6)}         │');
    print(
        '  │ Recall@5       : ${avgRecall.toStringAsFixed(4).padLeft(6)}         │');
    print('  │ F1 Score       : ${f1.toStringAsFixed(4).padLeft(6)}         │');
    print(
        '  │ MRR            : ${mrr.toStringAsFixed(4).padLeft(6)}         │');
    print('  └─────────────────────────────────────┘');
    print('${'=' * 70}\n');

    // 断言：确保基本检索质量
    expect(avgPrecision, greaterThan(0.3), reason: 'Precision@5 应大于 0.3');
    expect(mrr, greaterThan(0.4), reason: 'MRR 应大于 0.4');
  });
}
