/// ONNX Runtime Windows 桌面 Spike 测试
///
/// 目标：验证 flutter_onnxruntime 在 Windows 上能否正常工作。
/// 这是 tflite_flutter DLL 缺失后的替代方案验证。
///
/// 运行前必须：
///   1. flutter pub get
///   2. 生成 sine_model.onnx（见 generate_sine_onnx.py）
///   3. 将 sine_model.onnx 放到 assets/models/ 目录
///
/// 运行方式：
///   flutter test test/onnx_spike_test.dart
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

void main() {
  group('ONNX Runtime Spike', () {
    test('load model and run inference', () async {
      // ========== Step 0: 验证原生库加载 ==========
      // ignore: avoid_print
      print('🔧 Step 0: 初始化 ONNX Runtime...');

      late final OnnxRuntime ort;
      late final OrtSession session;

      try {
        ort = OnnxRuntime();
        // ignore: avoid_print
        print('✅ ONNX Runtime 原生库加载成功');
      } catch (e) {
        // ignore: avoid_print
        print('❌ ONNX Runtime 原生库加载失败: $e');
        return;
      }

      // ========== Step 1: 加载模型 ==========
      // ignore: avoid_print
      print('📦 Step 1: 加载 sine_model.onnx...');

      try {
        session =
            await ort.createSessionFromAsset('assets/models/sine_model.onnx');
        // ignore: avoid_print
        print('✅ 模型加载成功');
      } catch (e) {
        // ignore: avoid_print
        print('❌ 模型加载失败: $e');
        rethrow;
      }

      // ========== Step 2: 执行推理 ==========
      try {
        // ignore: avoid_print
        print('⚡ Step 2: 执行推理...');

        // sine_model 输入: [batch=1, features=1] → 值 1.0
        final inputs = {
          'input': await OrtValue.fromList([1.0], [1, 1]),
        };

        final stopwatch = Stopwatch()..start();
        final outputs = await session.run(inputs);
        stopwatch.stop();

        // ignore: avoid_print
        print('✅ 推理完成，耗时 ${stopwatch.elapsedMilliseconds}ms');

        // 检查输出
        if (outputs.isNotEmpty) {
          for (final entry in outputs.entries) {
            // ignore: avoid_print
            print('📊 输出 ${entry.key}: ${await entry.value.asList()}');
          }
        } else {
          // ignore: avoid_print
          print('📊 输出为空');
        }
      } catch (e) {
        // ignore: avoid_print
        print('❌ 推理执行失败: $e');
        rethrow;
      }

      // ========== Step 3: 连续推理稳定性 ==========
      try {
        // ignore: avoid_print
        print('🔁 Step 3: 连续 10 次推理...');

        for (int i = 0; i < 10; i++) {
          final sw = Stopwatch()..start();
          final inputs = {
            'input': await OrtValue.fromList([1.0], [1, 1]),
          };
          final outputs = await session.run(inputs);
          sw.stop();

          final values = await outputs.values.first.asList();
          // ignore: avoid_print
          print(
              '   第 ${i + 1} 次: ${sw.elapsedMilliseconds}ms, 输出: ${values.first.toStringAsFixed(4)}');
        }
        // ignore: avoid_print
        print('✅ 连续推理稳定');
      } catch (e) {
        // ignore: avoid_print
        print('❌ 连续推理失败: $e');
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
