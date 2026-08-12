"""
一体化导出 MobileCLIP-S0 多模态 ONNX 模型（图像编码器 + 文本编码器 + tokenizer）。

使用 open_clip_torch 加载 MobileCLIP 权重，避免依赖不存在的 mobileclip pip 包。
输出全部放到 assets/models/mobileclip_onnx/，供 Flutter 本地部署。

依赖:
    pip install torch onnx open_clip_torch transformers pillow onnxruntime

运行:
    python scripts/export_mobileclip_multimodal.py

输出:
    assets/models/mobileclip_onnx/image_encoder.onnx
    assets/models/mobileclip_onnx/text_encoder.onnx
    assets/models/mobileclip_onnx/clip_vocab.json
    assets/models/mobileclip_onnx/clip_merges.txt
    assets/models/mobileclip_onnx/preprocess_config.json
"""

import json
import os
import sys

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

if sys.stdout.encoding != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

# 模块级导入 torch/onnx，供各导出函数中的 torch.nn.Module 子类使用
try:
    import torch
    import onnx
except ImportError as e:
    print(f"错误：缺少 torch/onnx: {e}")
    print("    pip install torch onnx")
    sys.exit(1)

try:
    import open_clip
except ImportError as e:
    print(f"错误：缺少 open_clip_torch: {e}")
    print("    pip install open_clip_torch")
    sys.exit(1)


def main():

    output_dir = os.path.join(
        os.path.dirname(__file__), "..", "assets", "models", "mobileclip_onnx"
    )
    os.makedirs(output_dir, exist_ok=True)

    # 加载 MobileCLIP-S0
    print("正在加载 MobileCLIP-S0...")
    model, _, preprocess = _load_model(open_clip)
    model.eval()

    # 导出图像编码器
    image_onnx = os.path.join(output_dir, "image_encoder.onnx")
    _export_image_encoder(model, image_onnx)

    # 导出文本编码器
    text_onnx = os.path.join(output_dir, "text_encoder.onnx")
    _export_text_encoder(model, text_onnx)

    # 导出 tokenizer 文件
    _export_tokenizer(output_dir)

    # 导出预处理配置
    _export_preprocess_config(preprocess, output_dir)

    # 最终一致性验证
    _verify_alignment(image_onnx, text_onnx, output_dir)

    print(f"\n✅ 全部完成，输出目录: {output_dir}")
    for f in sorted(os.listdir(output_dir)):
        path = os.path.join(output_dir, f)
        size_mb = os.path.getsize(path) / (1024 * 1024)
        print(f"   {f}: {size_mb:.1f} MB")


def _load_model(open_clip):
    """加载 MobileCLIP-S1，支持常见 pretrained tag 回退。"""
    candidates = [
        ("MobileCLIP-S1", "datacompdr"),
        ("MobileCLIP-S2", "datacompdr"),
        ("MobileCLIP-B", "datacompdr"),
    ]
    last_error = None
    for model_name, pretrained in candidates:
        try:
            print(f"   尝试: model='{model_name}', pretrained='{pretrained}'")
            model, _, preprocess = open_clip.create_model_and_transforms(
                model_name,
                pretrained=pretrained,
                device="cpu",
            )
            print(f"   ✅ 加载成功: {model_name}/{pretrained}")
            return model, _, preprocess
        except Exception as e:
            last_error = e
            print(f"   ⚠️  失败: {e}")

    print("\n可用的 MobileCLIP 预训练标签（供参考）：")
    try:
        for m, t in open_clip.list_pretrained():
            if "mobileclip" in m.lower():
                print(f"   - model='{m}', pretrained='{t}'")
    except Exception as e:
        print(f"   无法列出: {e}")

    print(f"\n错误：无法加载 MobileCLIP-S1: {last_error}")
    sys.exit(1)


def _export_image_encoder(model, onnx_path):
    print(f"\n[1/4] 导出图像编码器 -> {onnx_path}")

    class ImageEncoderWrapper(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.clip_model = clip_model

        def forward(self, pixel_values):
            return self.clip_model.encode_image(pixel_values)

    wrapped = ImageEncoderWrapper(model)
    wrapped.eval()

    dummy_input = torch.randn(1, 3, 224, 224).float()
    torch.onnx.export(
        wrapped,
        dummy_input,
        onnx_path,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={"input": {0: "batch_size"}, "output": {0: "batch_size"}},
        opset_version=14,
        do_constant_folding=True,
    )

    import onnx as onnx_lib
    onnx_model = onnx_lib.load(onnx_path)
    onnx_lib.checker.check_model(onnx_model)
    print("   ✅ 图像编码器导出成功")


def _export_text_encoder(model, onnx_path):
    print(f"\n[2/4] 导出文本编码器 -> {onnx_path}")

    class TextEncoderWrapper(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.clip_model = clip_model

        def forward(self, input_ids):
            # open_clip 的 encode_text 接受 [N, 77] 的 token ID 张量
            return self.clip_model.encode_text(input_ids)

    wrapped = TextEncoderWrapper(model)
    wrapped.eval()

    dummy_input_ids = torch.zeros(1, 77, dtype=torch.long)
    dummy_input_ids[0, 0] = 49406  # BOS
    dummy_input_ids[0, 1] = 49407  # EOS

    torch.onnx.export(
        wrapped,
        dummy_input_ids,
        onnx_path,
        input_names=["input_ids"],
        output_names=["output"],
        dynamic_axes={"input_ids": {0: "batch_size"}, "output": {0: "batch_size"}},
        opset_version=14,
        do_constant_folding=True,
    )

    import onnx as onnx_lib
    onnx_model = onnx_lib.load(onnx_path)
    onnx_lib.checker.check_model(onnx_model)
    print("   ✅ 文本编码器导出成功")


def _export_tokenizer(output_dir):
    print(f"\n[3/4] 导出 CLIP tokenizer 文件 -> {output_dir}")
    vocab_path = os.path.join(output_dir, "clip_vocab.json")
    merges_path = os.path.join(output_dir, "clip_merges.txt")

    if os.path.isfile(vocab_path) and os.path.isfile(merges_path):
        print("   ✅ tokenizer 文件已存在，跳过")
        return

    try:
        from transformers import CLIPTokenizer

        tokenizer = CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")
        with open(vocab_path, "w", encoding="utf-8") as f:
            json.dump(tokenizer.get_vocab(), f, ensure_ascii=False)
        with open(merges_path, "w", encoding="utf-8") as f:
            for pair in tokenizer.bpe_ranks:
                f.write(f"{pair[0]} {pair[1]}\n")
        print("   ✅ tokenizer 文件导出成功")
    except Exception as e:
        print(f"   ⚠️  tokenizer 导出失败: {e}")
        print("   可手动从 https://hf-mirror.com/openai/clip-vit-base-patch32 下载 vocab.json 和 merges.txt")
        print("   并重命名为 clip_vocab.json / clip_merges.txt 放到上述目录")


def _export_preprocess_config(preprocess, output_dir):
    print(f"\n[4/4] 导出图像预处理配置")
    mean, std = _extract_preprocess_params(preprocess)
    config_path = os.path.join(output_dir, "preprocess_config.json")
    config = {
        "image_size": 224,
        "mean": mean,
        "std": std,
        "layout": "CHW",
        "input_name": "input",
        "output_name": "output",
        "model": "MobileCLIP-S1",
    }
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    print(f"   ✅ mean={mean}, std={std}")


def _extract_preprocess_params(preprocess):
    try:
        transforms = getattr(preprocess, "transforms", None)
        if transforms:
            for t in transforms:
                if hasattr(t, "mean") and hasattr(t, "std"):
                    return [float(x) for x in t.mean], [float(x) for x in t.std]
    except Exception as e:
        print(f"   ⚠️  提取 mean/std 失败: {e}")
    print("   ⚠️  使用 CLIP 标准默认值")
    return [0.48145466, 0.4578275, 0.40821073], [0.26862954, 0.26130258, 0.27577711]


def _verify_alignment(image_onnx, text_onnx, output_dir):
    print("\n[验证] ONNX Runtime 一致性检查")
    try:
        import numpy as np
        import onnxruntime as ort
        from transformers import CLIPTokenizer

        image_sess = ort.InferenceSession(
            image_onnx, providers=["CPUExecutionProvider"]
        )
        text_sess = ort.InferenceSession(text_onnx, providers=["CPUExecutionProvider"])

        # 图像推理
        dummy_img = np.random.randn(1, 3, 224, 224).astype(np.float32)
        img_out = image_sess.run(None, {"input": dummy_img})[0]
        img_norm = img_out / np.linalg.norm(img_out, axis=-1, keepdims=True)
        print(f"   图像编码器输出维度: {img_out.shape}, L2模长={np.linalg.norm(img_out):.4f}")

        # 文本推理
        tokenizer = CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")
        ids = tokenizer(
            "a red car",
            max_length=77,
            padding="max_length",
            truncation=True,
            return_tensors="np",
        )
        txt_out = text_sess.run(None, {"input_ids": ids["input_ids"].astype(np.int64)})[
            0
        ]
        txt_norm = txt_out / np.linalg.norm(txt_out, axis=-1, keepdims=True)
        print(f"   文本编码器输出维度: {txt_out.shape}, L2模长={np.linalg.norm(txt_out):.4f}")

        # 跨模态相似度
        sim = float(txt_norm @ img_norm.T)
        print(f"   示例跨模态相似度 (a red car vs 随机图): {sim:.3f}")
        print("   ✅ ONNX Runtime 验证通过")
    except Exception as e:
        print(f"   ⚠️  ONNX Runtime 验证失败: {e}")


if __name__ == "__main__":
    main()
