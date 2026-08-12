"""
将 bert-base-chinese 转换为 ONNX 格式，支持中文文本嵌入。

依赖:
    pip install optimum[onnxruntime] transformers torch

运行:
    python scripts/export_bert_chinese_onnx.py

输出:
    assets/models/bert_chinese_onnx/model.onnx  — 中文 BERT ONNX 模型
    assets/models/bert_chinese_onnx/vocab.txt   — 中文 WordPiece 词表
"""

import os
import sys


def main():
    try:
        from optimum.onnxruntime import ORTModelForFeatureExtraction
        from transformers import AutoTokenizer
    except ImportError:
        print("错误: 需要安装 optimum 和 transformers")
        print("运行: pip install optimum[onnxruntime] transformers")
        sys.exit(1)

    # bert-base-chinese 模型名
    model_name = "bert-base-chinese"
    output_dir = os.path.join(
        os.path.dirname(__file__), '..', 'assets', 'models', 'bert_chinese_onnx'
    )
    os.makedirs(output_dir, exist_ok=True)

    print(f"正在下载/加载模型: {model_name}")
    print("   首次运行需要从 HuggingFace 下载（约 400 MB）")
    print("   后续运行将使用本地缓存")

    try:
        # 加载模型并导出为 ONNX
        print("\nStep 1: 导出 ONNX 模型...")
        model = ORTModelForFeatureExtraction.from_pretrained(
            model_name,
            export=True,
        )
        model.save_pretrained(output_dir)
        print(f"✅ ONNX 模型已保存: {output_dir}")
    except Exception as e:
        print(f"❌ ONNX 导出失败: {e}")
        print("   如果 optimum-cli 不可用，尝试手动导出:")
        print(f"   optimum-cli export onnx --model {model_name} bert_chinese_onnx/")
        sys.exit(1)

    # Step 2: 导出 vocab.txt（Dart 分词器需要）
    print("\nStep 2: 导出 vocab.txt...")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    tokenizer.save_vocabulary(output_dir)
    vocab_path = os.path.join(output_dir, 'vocab.txt')
    print(f"✅ vocab.txt 已保存: {vocab_path}")

    # Step 3: 验证文件
    print("\nStep 3: 验证输出文件...")
    onnx_path = os.path.join(output_dir, 'model.onnx')
    vocab_path = os.path.join(output_dir, 'vocab.txt')

    if os.path.exists(onnx_path):
        size_mb = os.path.getsize(onnx_path) / (1024 * 1024)
        print(f"   📊 ONNX 模型大小: {size_mb:.1f} MB")
    else:
        print("   ❌ 未找到 model.onnx")

    if os.path.exists(vocab_path):
        with open(vocab_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        print(f"   📊 词表大小: {len(lines)} tokens")
    else:
        print("   ❌ 未找到 vocab.txt")

    print(f"\n📁 输出目录: {output_dir}")
    print("\n" + "=" * 60)
    print("下一步:")
    print("  1. 在 pubspec.yaml 的 assets 中添加 assets/models/bert_chinese_onnx/")
    print("  2. 在 embedding_engine.dart 中更新模型路径")
    print("  3. 运行测试验证中文嵌入效果")
    print("=" * 60)


if __name__ == '__main__':
    main()
