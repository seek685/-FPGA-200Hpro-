#!/usr/bin/env python3
"""Train a small RGB CNN and export the exact integer arithmetic used by roi_cnn_core.

Architecture adapted from SweiryDev/MicroCNN-TangNano20k (MIT); see third_party.
New training data, weights, memory layout and portable RTL are separate from its
BloodMNIST weights. Input is RGB uint8 / 256, not mean-subtracted or BGR.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import random

import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F

CLASSES = ["APPLE", "BANANA", "ORANGE", "OTHER"]
LAYERS = ["conv1", "conv2", "fc1", "fc2"]
SEED = 20261015


class MicroCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(3, 8, 3)
        self.conv2 = nn.Conv2d(8, 16, 3)
        self.fc1 = nn.Linear(400, 32)
        self.fc2 = nn.Linear(32, 4)

    def forward(self, x, taps=False):
        a = F.max_pool2d(F.relu(self.conv1(x)), 2)
        b = F.max_pool2d(F.relu(self.conv2(a)), 2)
        c = F.relu(self.fc1(b.flatten(1)))
        y = self.fc2(c)
        return (a, b, c, y) if taps else y


def synthetic_background(count, seed):
    """Negative examples only; these are not a general open-set detector."""
    rng = np.random.default_rng(seed)
    images = []
    yy, xx = np.mgrid[:28, :28]
    for i in range(count):
        base = rng.uniform(25, 255, (1, 1, 3))
        if i % 3:
            base[:] = base.mean()
        a = np.broadcast_to(base, (28, 28, 3)).copy()
        a += (xx[..., None] - 14) * rng.uniform(-3, 3)
        a += rng.normal(0, rng.uniform(0, 12), a.shape)
        if i % 4 == 0:
            for _ in range(3):
                x, y = rng.integers(0, 23, 2)
                a[y:y + rng.integers(1, 5), x:x + rng.integers(2, 8)] = rng.uniform(0, 220)
        images.append(np.clip(a, 0, 255).astype(np.uint8))
    return np.stack(images)


def load_data(root):
    manifest = json.loads((root / "manifest.json").read_text())
    train, validation, test = [], [], []
    rng = np.random.default_rng(SEED)
    grouped = {}
    for e in manifest["entries"]:
        # The manifest uses Git/URL paths on every host, including Windows.
        grouped.setdefault(str(PurePosixPath(e["path"]).parent), []).append(e)
    for group, entries in grouped.items():
        order = rng.permutation(len(entries))
        val_count = max(1, len(entries) // 5)
        for order_index, i in enumerate(order):
            entry = entries[i]
            with Image.open(root / entry["path"]) as im:
                rgb = np.array(im.convert("RGB").resize((28, 28), Image.Resampling.BOX))
            item = (rgb, entry["label"], entry["path"])
            destination = test if group.startswith("Test/") else validation if order_index < val_count else train
            destination.append(item)
    for items, count, seed in [(train, 400, SEED + 1), (validation, 100, SEED + 2), (test, 100, SEED + 3)]:
        items.extend((im, 3, f"synthetic/{seed}/{i}") for i, im in enumerate(synthetic_background(count, seed)))
    def arrays(items):
        if set(v[1] for v in items) != {0, 1, 2, 3}:
            raise ValueError("Every split must contain all four classes")
        x = torch.tensor(np.stack([v[0] for v in items]).transpose(0, 3, 1, 2), dtype=torch.float32) / 256
        y = torch.tensor([v[1] for v in items], dtype=torch.long)
        return x, y, [v[2] for v in items]
    return arrays(train), arrays(validation), arrays(test), manifest


def augment(x):
    n = len(x)
    angle = (torch.rand(n) * 2 - 1) * math.pi
    scale = torch.rand(n) * 0.55 + 0.8
    theta = torch.zeros(n, 2, 3)
    theta[:, 0, 0] = angle.cos() * scale
    theta[:, 0, 1] = -angle.sin() * scale
    theta[:, 1, 0] = angle.sin() * scale
    theta[:, 1, 1] = angle.cos() * scale
    theta[:, :, 2] = (torch.rand(n, 2) * 2 - 1) * 0.12
    grid = F.affine_grid(theta, x.shape, align_corners=False)
    x = F.grid_sample(x - 255 / 256, grid, align_corners=False) + 255 / 256
    gain = torch.rand(n, 1, 1, 1) * 0.40 + 0.70
    wb = torch.rand(n, 3, 1, 1) * 0.20 + 0.90
    x = x * gain * wb + torch.randn_like(x) * (2 / 256)
    return (x.clamp(0, 255 / 256) * 256).round() / 256


@torch.no_grad()
def evaluate(model, x, y):
    output = torch.cat([model(b) for b in x.split(128)])
    return float((output.argmax(1) == y).float().mean()), float(F.cross_entropy(output, y)), output


def quantize(model, calibration):
    with torch.no_grad():
        taps = [model(x, taps=True) for x in calibration.split(128)]
        maxima = [max(float(t[i].max()) for t in taps) for i in range(3)]
    q = {}
    input_exp = 8
    shifts = []
    scales = []
    for i, name in enumerate(LAYERS):
        layer = getattr(model, name)
        w = layer.weight.detach().numpy()
        b = layer.bias.detach().numpy()
        weight_exp = math.floor(math.log2(127 / max(float(np.abs(w).max()), 1e-8)))
        weight_exp = min(weight_exp, 14)
        q[name + "_w"] = np.clip(np.rint(w * 2.0 ** weight_exp), -128, 127).astype(np.int8)
        bias = np.rint(b * 2.0 ** (input_exp + weight_exp))
        if np.max(np.abs(bias)) >= 2 ** 30:
            raise RuntimeError("Bias exceeds the signed accumulator budget")
        q[name + "_b"] = bias.astype(np.int32)
        if i < 3:
            output_exp = math.floor(math.log2(240 / max(maxima[i], 1e-8)))
            shift = input_exp + weight_exp - output_exp
            if not 0 <= shift <= 24:
                raise RuntimeError(f"Unsupported shift {shift} at {name}")
            shifts.append(shift)
            scales.append({"input_exp": input_exp, "weight_exp": weight_exp, "output_exp": output_exp, "calibration_max": maxima[i]})
            input_exp = output_exp
        else:
            scales.append({"input_exp": input_exp, "weight_exp": weight_exp, "output_exp": input_exp + weight_exp})
    q["shifts"] = np.array(shifts, dtype=np.int32)
    return q, scales


def integer_forward(x, q, return_taps=False):
    """Independent NumPy int64 accumulation; all ROM and activation ordering is CHW.

    Check int32 limits before any truncation. There is no floating-point arithmetic
    in this reference inference and no dependence on PyTorch convolution.
    """
    def conv(a, w, b):
        patches = np.lib.stride_tricks.sliding_window_view(a, (3, 3), axis=(-2, -1))
        acc = np.einsum("nchwkl,ockl->nohw", patches.astype(np.int64), w.astype(np.int64), optimize=True)
        return acc + b[None, :, None, None].astype(np.int64)
    def activation(a, shift):
        if a.min() < -(2 ** 31) or a.max() >= 2 ** 31:
            raise OverflowError("32-bit accumulator overflow")
        return np.clip(np.maximum(a, 0) >> int(shift), 0, 255).astype(np.uint8)
    def pool(a):
        h, w = a.shape[-2] // 2, a.shape[-1] // 2
        return a[:, :, :h * 2, :w * 2].reshape(len(a), a.shape[1], h, 2, w, 2).max(axis=(3, 5))
    a1 = activation(conv(x, q["conv1_w"], q["conv1_b"]), q["shifts"][0])
    p1 = pool(a1)
    a2 = activation(conv(p1, q["conv2_w"], q["conv2_b"]), q["shifts"][1])
    p2 = pool(a2)
    a3 = activation(p2.reshape(len(x), -1).astype(np.int64) @ q["fc1_w"].astype(np.int64).T + q["fc1_b"], q["shifts"][2])
    y = a3.astype(np.int64) @ q["fc2_w"].astype(np.int64).T + q["fc2_b"]
    if y.min() < -(2 ** 31) or y.max() >= 2 ** 31:
        raise OverflowError("Final accumulator overflow")
    return (a1, p1, a2, p2, a3, y) if return_taps else y


def write_hex(path, array, bits):
    digits, mask = bits // 4, (1 << bits) - 1
    path.write_text("".join(f"{int(v) & mask:0{digits}x}\n" for v in array.reshape(-1)))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dataset", type=Path)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--epochs", type=int, default=45)
    p.add_argument("--threads", type=int, default=4)
    args = p.parse_args()
    random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
    torch.set_num_threads(args.threads)
    torch.use_deterministic_algorithms(True)
    args.output.mkdir(parents=True, exist_ok=True)
    (train_x, train_y, train_paths), (val_x, val_y, val_paths), (test_x, test_y, test_paths), manifest = load_data(args.dataset)
    model = MicroCNN()
    optimizer = torch.optim.AdamW(model.parameters(), lr=0.003, weight_decay=0.0001)
    counts = torch.bincount(train_y, minlength=4).float()
    class_weights = counts.sum() / (4 * counts)
    best_key, best_state, best_epoch = (-1, -float("inf")), None, 0
    print("samples train/validation/test", len(train_y), len(val_y), len(test_y), "train classes", counts.tolist(), flush=True)
    history = []
    for epoch in range(args.epochs):
        model.train()
        order = torch.randperm(len(train_x))
        loss_sum = 0
        for ids in order.split(64):
            optimizer.zero_grad()
            logits = model(augment(train_x[ids]))
            loss = F.cross_entropy(logits, train_y[ids], weight=class_weights)
            loss.backward(); optimizer.step()
            loss_sum += float(loss.detach()) * len(ids)
        model.eval()
        accuracy, val_loss, _ = evaluate(model, val_x, val_y)
        history.append({"epoch": epoch + 1, "train_loss": loss_sum / len(train_y), "validation_accuracy": accuracy, "validation_loss": val_loss})
        if (accuracy, -val_loss) > best_key:
            best_key = (accuracy, -val_loss); best_epoch = epoch + 1
            best_state = copy.deepcopy(model.state_dict())
        if epoch % 5 == 0 or epoch == args.epochs - 1:
            print(history[-1], flush=True)
    model.load_state_dict(best_state); model.eval()
    # Select epoch using validation only. Test is first evaluated below.
    q, scales = quantize(model, train_x)
    integer_scores = []
    input_u8 = (test_x.numpy() * 256).astype(np.uint8)
    for begin in range(0, len(input_u8), 32):
        integer_scores.append(integer_forward(input_u8[begin:begin + 32], q))
    scores = np.concatenate(integer_scores)
    predictions = scores.argmax(1)
    labels = test_y.numpy()
    confusion = np.zeros((4, 4), dtype=int)
    np.add.at(confusion, (labels, predictions), 1)
    float_accuracy, _, _ = evaluate(model, test_x, test_y)
    np.savez_compressed(args.output / "float_model.npz", **{k: v.numpy() for k, v in model.state_dict().items()})
    np.savez_compressed(args.output / "integer_model.npz", **q)
    (args.output / "roi_cnn_model.vh").write_text(
        "// Generated together with the integer model and ROMs.\n"
        "`ifndef ROI_CNN_MODEL_VH\n`define ROI_CNN_MODEL_VH\n" +
        "".join(f"`define ROI_CNN_SHIFT{i + 1} {int(shift)}\n" for i, shift in enumerate(q["shifts"])) +
        "`endif\n")
    for key, data in q.items():
        if key != "shifts":
            write_hex(args.output / (key + ".mem"), data, 32 if key.endswith("_b") else 8)
    selected = []
    for label in range(4):
        candidates = np.flatnonzero(labels == label)
        # Deterministic coverage, not chosen for correct predictions.
        selected.extend(candidates[np.linspace(0, len(candidates) - 1, 2, dtype=int)].tolist())
    fixture_images = input_u8[selected].transpose(0, 2, 3, 1)
    packed = (fixture_images[..., 0].astype(np.uint32) << 16) | (fixture_images[..., 1].astype(np.uint32) << 8) | fixture_images[..., 2]
    write_hex(args.output / "test_images_rgb.mem", packed, 24)
    write_hex(args.output / "test_logits.mem", scores[selected], 32)
    write_hex(args.output / "test_classes.mem", predictions[selected], 8)
    fixtures = args.output / "fixtures"
    fixtures.mkdir(exist_ok=True)
    for index, sample in enumerate(selected):
        Image.fromarray(input_u8[sample].transpose(1, 2, 0)).save(fixtures / f"{index}_{CLASSES[labels[sample]]}.png")
    report = {
        "classes": CLASSES, "architecture": "RGB28-Conv3x3(3,8)-ReLU-Pool2-Conv3x3(8,16)-ReLU-Pool2-FC(400,32)-ReLU-FC(32,4)",
        "seed": SEED, "source_repository": manifest["repository"], "source_revision": manifest["revision"],
        "environment": {"torch": torch.__version__, "numpy": np.__version__, "pillow": Image.__version__},
        "dataset_manifest_sha256": hashlib.sha256((args.dataset / "manifest.json").read_bytes()).hexdigest(),
        "training_samples": len(train_y), "validation_samples": len(val_y), "test_samples": len(test_y),
        "best_epoch": best_epoch, "float_test_accuracy": float_accuracy,
        "integer_test_accuracy": float(np.mean(predictions == labels)), "confusion_matrix_actual_by_predicted": confusion.tolist(),
        "shifts": q["shifts"].tolist(), "quantization": scales,
        "fixture_source_paths": [test_paths[i] for i in selected], "fixture_labels": labels[selected].tolist(),
        "fixture_predictions": predictions[selected].tolist(), "history": history,
        "limits": ["Fixed-ROI single-object classification, not object detection.",
                   "Test accuracy is on the selected Fruits-360 subset and synthetic negatives, not a live HDMI camera.",
                   "Train and validation images include correlated rotations; this is not a held-out-object generalization study.",
                   "OTHER is trained on kiwi, lemon, pear and synthetic backgrounds; it does not guarantee rejection of all unseen objects.",
                   "Dataset objects have white backgrounds; use a plain light background for initial board bring-up."]}
    (args.output / "model_report.json").write_text(json.dumps(report, indent=2) + "\n")
    (args.output / "split_manifest.json").write_text(json.dumps({"training": train_paths, "validation": val_paths, "test": test_paths}, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ["best_epoch", "float_test_accuracy", "integer_test_accuracy", "confusion_matrix_actual_by_predicted", "shifts", "fixture_predictions"]}, indent=2), flush=True)


if __name__ == "__main__":
    main()
