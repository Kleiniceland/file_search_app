"""
将 BERT-base-uncased 转换为 ONNX 格式，用于 flutter_onnxruntime 推理。

使用 HuggingFace optimum-cli 导出，同时导出 vocab.txt 用于 Dart 分词器。

依赖:
    pip install optimum[onnxruntime] transformers torch

运行:
    python export_bert_onnx.py

输出:
    assets/models/bert_onnx/model.onnx  — BERT ONNX 模型
    assets/models/bert_onnx/vocab.txt   — WordPiece 词表（Dart 分词器用）
"""

import os
import sys
import shutil


def main():
    try:
        from optimum.onnxruntime import ORTModelForFeatureExtraction
        from transformers import AutoTokenizer
    except ImportError:
        print("错误: 需要安装 optimum 和 transformers")
        print("运行: pip install optimum[onnxruntime] transformers")
        sys.exit(1)

    # 本地 snapshot 路径（手动下载了 model.safetensors）
    # 如果包含完整文件集（config.json + vocab.txt），直接用本地路径
    local_snapshot = r"C:\Users\白昼烟花\.cache\huggingface\hub\models--bert-base-uncased\snapshots\86b5e0934494bd15c9632b12f734a8a67f723594"
    has_local_files = (
        os.path.exists(os.path.join(local_snapshot, 'config.json'))
        and os.path.exists(os.path.join(local_snapshot, 'vocab.txt'))
    )
    # 优先用本地路径，否则回退到在线模型名（让 transformers 自动下载）
    model_source = local_snapshot if has_local_files else "bert-base-uncased"
    output_dir = os.path.join(
        os.path.dirname(__file__), '..', 'assets', 'models', 'bert_onnx'
    )
    os.makedirs(output_dir, exist_ok=True)

    # Step 1: 导出 ONNX 模型
    print(f"正在加载模型: {model_source}")
    if has_local_files:
        print("   ✅ 检测到本地完整文件集，使用本地路径（离线）")
    else:
        print("   ⚠️  本地文件不完整，回退到在线下载（需要网络）")
        print("   如果网络不通，请手动下载 config.json / vocab.txt 到:")
        print(f"   {local_snapshot}")

    try:
        model = ORTModelForFeatureExtraction.from_pretrained(
            model_source,
            export=True,
        )
        model.save_pretrained(output_dir)
        print(f"✅ ONNX 模型已保存: {output_dir}")
    except Exception as e:
        print(f"❌ ONNX 导出失败: {e}")
        print("   如果 optimum-cli 不可用，尝试手动导出:")
        print(f"   optimum-cli export onnx --model {model_source} bert_onnx/")
        sys.exit(1)

    # Step 2: 导出 vocab.txt（Dart 分词器需要）
    print("正在导出 vocab.txt...")
    tokenizer = AutoTokenizer.from_pretrained(model_source)
    # save_vocabulary 接收的是"目录"，不是文件路径
    # 它会在该目录下自动创建 vocab.txt
    tokenizer.save_vocabulary(output_dir)
    vocab_path = os.path.join(output_dir, 'vocab.txt')
    print(f"✅ vocab.txt 已保存: {vocab_path}")

    # Step 3: 验证文件
    onnx_path = os.path.join(output_dir, 'model.onnx')
    if os.path.exists(onnx_path):
        size_mb = os.path.getsize(onnx_path) / (1024 * 1024)
        print(f"\n📊 BERT ONNX 模型大小: {size_mb:.1f} MB")
        if size_mb > 50:
            print("   ⚠️  模型超过 50 MB，考虑使用动态量化或更小的模型")
            print("   可选替代: distilbert-base-uncased (约 26 MB)")
    else:
        print("❌ 未找到 model.onnx")

    print(f"\n📁 输出目录: {output_dir}")
    print("   下一步: 在 pubspec.yaml 的 assets 中添加 assets/models/")


if __name__ == '__main__':
    main()
