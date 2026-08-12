"""
将轻量中文 RoBERTa 模型转换为 ONNX 格式。

使用 UER-py 预训练的 chinese_roberta_L-6_H-512（6 层，512 维，~50 MB），
替代原 bert-base-chinese（12 层，768 维，~400 MB），大幅减少内存占用。

模型兼容 BERT 架构，可直接复用现有的 WordPiece 分词器和 ONNX 推理逻辑。

依赖:
    pip install optimum[onnxruntime] transformers torch

运行:
    python scripts/export_tinybert_chinese_onnx.py

输出:
    assets/models/bert_chinese_onnx/model.onnx  — 轻量 ONNX 模型
    assets/models/bert_chinese_onnx/vocab.txt   — WordPiece 词表
"""

import os
import sys

# 使用 HuggingFace 镜像站（解决国内连接超时问题）
os.environ['HF_ENDPOINT'] = 'https://hf-mirror.com'


def main():
    try:
        from optimum.onnxruntime import ORTModelForFeatureExtraction
        from transformers import AutoTokenizer, AutoConfig
    except ImportError:
        print("错误: 需要安装 optimum 和 transformers")
        print("运行: pip install optimum[onnxruntime] transformers")
        sys.exit(1)

    # UER 中文 RoBERTa 轻量模型（6 层，512 维）
    model_name = "uer/chinese_roberta_L-6_H-512"
    output_dir = os.path.join(
        os.path.dirname(__file__), '..', 'assets', 'models', 'bert_chinese_onnx'
    )
    os.makedirs(output_dir, exist_ok=True)

    print(f"正在下载/加载模型: {model_name}")
    print("   首次运行需要从 HuggingFace 下载（约 50 MB）")

    # 先检查模型配置
    try:
        config = AutoConfig.from_pretrained(model_name)
        print(f"   模型配置: {config.num_hidden_layers} 层, "
              f"{config.hidden_size} 维, "
              f"{config.num_attention_heads} 注意力头")
    except Exception as e:
        print(f"   [WARN] 无法读取配置: {e}")

    try:
        # Step 1: 导出 ONNX 模型
        print("\nStep 1: 导出 ONNX 模型...")
        model = ORTModelForFeatureExtraction.from_pretrained(
            model_name,
            export=True,
        )
        model.save_pretrained(output_dir)
        print(f"[OK] ONNX 模型已保存: {output_dir}")
    except Exception as e:
        print(f"[FAIL] ONNX 导出失败: {e}")
        print("   如果 optimum-cli 不可用，尝试手动导出:")
        print(f"   optimum-cli export onnx --model {model_name} bert_chinese_onnx/")
        sys.exit(1)

    # Step 2: 导出 vocab.txt（Dart 分词器需要）
    print("\nStep 2: 导出 vocab.txt...")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    tokenizer.save_vocabulary(output_dir)
    vocab_path = os.path.join(output_dir, 'vocab.txt')
    print(f"[OK] vocab.txt 已保存: {vocab_path}")

    # Step 3: 验证文件
    print("\nStep 3: 验证输出文件...")
    onnx_path = os.path.join(output_dir, 'model.onnx')
    vocab_path = os.path.join(output_dir, 'vocab.txt')

    if os.path.exists(onnx_path):
        size_mb = os.path.getsize(onnx_path) / (1024 * 1024)
        print(f"   [OK] ONNX 模型大小: {size_mb:.1f} MB")
    else:
        print("   [FAIL] 未找到 model.onnx")
        sys.exit(1)

    if os.path.exists(vocab_path):
        with open(vocab_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        print(f"   [OK] 词表大小: {len(lines)} tokens")
    else:
        print("   [FAIL] 未找到 vocab.txt")
        sys.exit(1)

    # Step 4: 验证 ONNX 模型输出维度
    print("\nStep 4: 验证 ONNX 模型...")
    try:
        import onnxruntime as ort
        import numpy as np

        sess = ort.InferenceSession(onnx_path, providers=['CPUExecutionProvider'])

        # 打印输入/输出信息
        print("   输入:")
        for inp in sess.get_inputs():
            print(f"     {inp.name}: {inp.shape} ({inp.type})")
        print("   输出:")
        for out in sess.get_outputs():
            print(f"     {out.name}: {out.shape} ({out.type})")

        # 简单推理测试
        input_ids = np.zeros((1, 128), dtype=np.int64)
        input_ids[0, 0] = 101  # [CLS]
        input_ids[0, 1] = 100  # [UNK]
        input_ids[0, 2] = 102  # [SEP]
        attention_mask = np.ones((1, 128), dtype=np.int64)
        token_type_ids = np.zeros((1, 128), dtype=np.int64)

        # 尝试不同的输入组合
        try:
            outputs = sess.run(None, {
                'input_ids': input_ids,
                'attention_mask': attention_mask,
                'token_type_ids': token_type_ids,
            })
        except Exception:
            outputs = sess.run(None, {
                'input_ids': input_ids,
                'attention_mask': attention_mask,
            })

        print(f"   [OK] 推理测试通过，输出形状: {outputs[0].shape}")
        print(f"   [OK] 输出非 NaN: {not np.isnan(outputs[0]).any()}")

    except Exception as e:
        print(f"   [WARN] ONNX 验证失败: {e}")

    print(f"\n输出目录: {output_dir}")
    print("\n" + "=" * 60)
    print("下一步:")
    print("  1. 更新 embedding_engine.dart 中的 kTextEmbeddingDim")
    print("  2. 运行测试验证中文嵌入效果")
    print("=" * 60)


if __name__ == '__main__':
    main()
