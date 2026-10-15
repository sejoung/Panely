#!/usr/bin/env python3
"""
Build Panely/Resources/ComicTextDetector.mlpackage — the balloon and text
detector the translation assist groups OCR text with.

Source model: ogkalu/comic-text-and-bubble-detector (RT-DETR-v2, Apache-2.0,
trained on ~11k manga, webtoon, manhua and western comic images). Classes:
0 bubble, 1 text_bubble (text inside a balloon), 2 text_free (text outside).

Converted for a fixed 640×640 RGB input (the size it was trained at; pages are
stretched to it, as its own preprocessor does), with 8-bit k-means
palettized weights: ~42 MB, and on the GPU its boxes match the PyTorch
original's (mean IoU 0.99 over 271 boxes on 48 pages). Run it on the GPU —
the Neural Engine's float16 math drifts on this model (IoU ~0.87).

Outputs:
  scores  (1, 300, 3)  per-query class probabilities (sigmoid applied)
  boxes   (1, 300, 4)  cx, cy, w, h, normalized to 0–1

Usage (needs Python 3.12 and ~2 GB of packages; nothing needs a GPU):
  python3 -m venv /tmp/detector-env
  /tmp/detector-env/bin/pip install "torch==2.7.0" transformers coremltools scikit-learn safetensors
  /tmp/detector-env/bin/python scripts/convert-text-detector.py

torch is pinned to 2.7.0, the newest coremltools 9 is tested with.
"""
import os
import sys

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as ct_ops
from transformers import RTDetrV2ForObjectDetection
from transformers.models.rt_detr_v2.modeling_rt_detr_v2 import RTDetrV2SinePositionEmbedding

REPO = "ogkalu/comic-text-and-bubble-detector"
SIZE = 640
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Panely", "Resources", "ComicTextDetector.mlpackage")


# coremltools casts a constant one-element array with int(array), which
# numpy no longer allows for non-scalars; use .item() for those.
_original_cast = ct_ops._cast


def _cast(context, node, dtype, dtype_name):
    x = ct_ops._get_inputs(context, node, expected=1)[0]
    if x.can_be_folded_to_const() and isinstance(x.val, np.ndarray) and x.val.size == 1:
        context.add(mb.const(val=dtype(x.val.item()), name=node.name), node.name)
        return
    _original_cast(context, node, dtype, dtype_name)


ct_ops._cast = _cast


class FixedPositionEmbedding(torch.nn.Module):
    """The encoder's sine position table, precomputed. It's rebuilt from
    integer coordinates on every call (an int × float matmul Core ML refuses);
    for a fixed input size it's always the same table."""

    def __init__(self, table):
        super().__init__()
        self.register_buffer("table", table)

    def forward(self, width, height, device, dtype):
        return self.table.to(dtype)


def bake_position_embeddings(module):
    for name, child in module.named_children():
        if isinstance(child, RTDetrV2SinePositionEmbedding):
            side = SIZE // 32  # the encoder runs on the stride-32 level
            table = child(width=side, height=side, device=torch.device("cpu"), dtype=torch.float32).clone()
            setattr(module, name, FixedPositionEmbedding(table))
        else:
            bake_position_embeddings(child)


class Detector(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image):
        out = self.model(pixel_values=image)
        return out.logits.sigmoid(), out.pred_boxes


def main():
    # Fixed anchors for the fixed input size. (Not `eval_size`: in this
    # transformers version it drops the position embedding altogether.)
    model = RTDetrV2ForObjectDetection.from_pretrained(REPO, anchor_image_size=[SIZE, SIZE]).eval()
    bake_position_embeddings(model)
    with torch.no_grad():
        traced = torch.jit.trace(Detector(model).eval(), torch.rand(1, 3, SIZE, SIZE), strict=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="scores"), ct.TensorType(name="boxes")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    config = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(nbits=8, mode="kmeans", weight_threshold=2048))
    mlmodel = cto.palettize_weights(mlmodel, config=config)
    mlmodel.short_description = (
        "Comic speech balloon and text detector — RT-DETR-v2 from "
        "huggingface.co/ogkalu/comic-text-and-bubble-detector (Apache-2.0). "
        "Classes: 0 bubble, 1 text_bubble, 2 text_free."
    )
    mlmodel.license = "Apache-2.0"
    mlmodel.input_description["image"] = f"Page (or part of a strip) stretched to {SIZE}×{SIZE} RGB"
    mlmodel.output_description["scores"] = "Per-query class probabilities (1, 300, 3)"
    mlmodel.output_description["boxes"] = "Per-query boxes cx, cy, w, h in 0–1 (1, 300, 4)"
    mlmodel.save(os.path.abspath(OUTPUT))
    print("Saved", os.path.abspath(OUTPUT))


if __name__ == "__main__":
    sys.exit(main())
