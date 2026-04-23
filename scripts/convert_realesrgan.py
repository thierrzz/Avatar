#!/usr/bin/env python3
"""
Convert Real-ESRGAN super-resolution models to CoreML for Avatar.

Developer build tool — run once per variant to produce compiled .mlmodelc
bundles that can be zipped and hosted for in-app download.

Produces one of:
    build/RealESRGAN_x2.mlmodelc/  +  .zip   (2× model — RealESRGAN_x2plus)
    build/RealESRGAN_x4.mlmodelc/  +  .zip   (4× model — realesr-general-x4v3)

Usage:
    pip3 install torch coremltools realesrgan basicsr pillow
    python3 scripts/convert_realesrgan.py --variant x2
    python3 scripts/convert_realesrgan.py --variant x4
    python3 scripts/convert_realesrgan.py --variant x4 --install

The conversion traces the generator with a fixed 256×256 input (a reasonable
latency/quality sweet-spot for the Avatar editor) and declares an
EnumeratedShapes set covering 256, 384, 512, 768, 1024 inputs so the Swift
side can send any of those without a re-compile.

Keep MODEL_VERSION in sync with UpscaleModelManager.Variant.currentVersion.
"""

import argparse
import os
import shutil
import subprocess
import sys

# ─── Configuration ────────────────────────────────────────────────────────────

MODEL_VERSION = "v1"  # keep in sync with UpscaleModelManager.Variant.currentVersion

VARIANTS = {
    "x2": {
        "compiled_name": "RealESRGAN_x2.mlmodelc",
        "zip_name": "RealESRGAN_x2.mlmodelc.zip",
        # Released weights for RealESRGAN_x2plus from xinntao/Real-ESRGAN.
        "weights_url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        "weights_filename": "RealESRGAN_x2plus.pth",
        "scale": 2,
        "num_block": 23,
    },
    "x4": {
        "compiled_name": "RealESRGAN_x4.mlmodelc",
        "zip_name": "RealESRGAN_x4.mlmodelc.zip",
        "weights_url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth",
        "weights_filename": "realesr-general-x4v3.pth",
        "scale": 4,
        # general-x4v3 uses SRVGGNetCompact, not RRDBNet.
        "compact": True,
    },
}

# RRDBNet (x2plus) applies pixel_unshuffle on variable-size inputs, which the
# Core ML MIL backend rejects as a rank-6 reshape. We therefore pin a single
# fixed input size. The Swift side resizes the source to exactly this before
# invoking the model, then we get an N× output in return.
FIXED_INPUT_SIZE = 512

# ─── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
BUILD_DIR = os.path.join(REPO_ROOT, "build")
WEIGHTS_DIR = os.path.join(BUILD_DIR, "weights")

APP_SUPPORT_DIR = os.path.expanduser(
    "~/Library/Application Support/Avatar/Models"
)

# ─── Helpers ──────────────────────────────────────────────────────────────────

def fetch_weights(variant_cfg):
    os.makedirs(WEIGHTS_DIR, exist_ok=True)
    dest = os.path.join(WEIGHTS_DIR, variant_cfg["weights_filename"])
    if os.path.exists(dest):
        print(f"[convert] weights already present: {dest}")
        return dest
    import urllib.request
    print(f"[convert] downloading {variant_cfg['weights_url']}")
    urllib.request.urlretrieve(variant_cfg["weights_url"], dest)
    return dest


def build_generator(variant_cfg, weights_path):
    import torch

    if variant_cfg.get("compact"):
        # realesr-general-x4v3 uses the lightweight SRVGGNetCompact generator.
        from basicsr.archs.srvgg_arch import SRVGGNetCompact
        net = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64,
                              num_conv=32, upscale=variant_cfg["scale"],
                              act_type="prelu")
    else:
        # RealESRGAN_x2plus / x4plus use RRDBNet.
        from basicsr.archs.rrdbnet_arch import RRDBNet
        net = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                      num_block=variant_cfg.get("num_block", 23),
                      num_grow_ch=32, scale=variant_cfg["scale"])

    state = torch.load(weights_path, map_location="cpu")
    # Real-ESRGAN checkpoints store weights under "params_ema" or "params".
    key = "params_ema" if "params_ema" in state else "params"
    net.load_state_dict(state[key], strict=True)
    net.eval()
    return net


def convert(variant):
    import torch
    import coremltools as ct

    cfg = VARIANTS[variant]
    weights_path = fetch_weights(cfg)
    net = build_generator(cfg, weights_path)

    example = torch.rand(1, 3, FIXED_INPUT_SIZE, FIXED_INPUT_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(net, example)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input",
                shape=(1, 3, FIXED_INPUT_SIZE, FIXED_INPUT_SIZE),
                scale=1.0 / 255.0,      # uint8 → float
                bias=[0, 0, 0],
                channel_first=True,
            )
        ],
        outputs=[
            ct.ImageType(name="output")
        ],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )

    mlmodel.short_description = (
        f"Real-ESRGAN {variant} super-resolution "
        f"(scale={cfg['scale']}, Avatar {MODEL_VERSION})"
    )

    # ─── Save + compile ───────────────────────────────────────────────────────
    os.makedirs(BUILD_DIR, exist_ok=True)
    mlpackage_path = os.path.join(BUILD_DIR, f"RealESRGAN_{variant}.mlpackage")
    if os.path.exists(mlpackage_path):
        shutil.rmtree(mlpackage_path)
    mlmodel.save(mlpackage_path)
    print(f"[convert] saved {mlpackage_path}")

    compiled_path = os.path.join(BUILD_DIR, cfg["compiled_name"])
    if os.path.exists(compiled_path):
        shutil.rmtree(compiled_path)

    # Compile .mlpackage → .mlmodelc using Apple's model compiler.
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlpackage_path, BUILD_DIR],
        check=True,
    )
    # coremlcompiler emits the compiled directory with the same stem as the
    # input; rename to the expected `.mlmodelc` suffix if needed.
    produced = os.path.join(BUILD_DIR, f"RealESRGAN_{variant}.mlmodelc")
    if produced != compiled_path and os.path.exists(produced):
        shutil.move(produced, compiled_path)
    print(f"[convert] compiled {compiled_path}")

    # ─── Zip for hosting ──────────────────────────────────────────────────────
    zip_path = os.path.join(BUILD_DIR, cfg["zip_name"])
    if os.path.exists(zip_path):
        os.remove(zip_path)
    subprocess.run(
        ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
         compiled_path, zip_path],
        check=True,
    )
    print(f"[convert] zipped → {zip_path}")

    return compiled_path, zip_path


def install_locally(compiled_path, variant):
    cfg = VARIANTS[variant]
    os.makedirs(APP_SUPPORT_DIR, exist_ok=True)
    dest = os.path.join(APP_SUPPORT_DIR, cfg["compiled_name"])
    if os.path.exists(dest):
        shutil.rmtree(dest)
    shutil.copytree(compiled_path, dest)
    # Stamp the version sidecar so UpscaleModelManager considers it current.
    sidecar = os.path.join(APP_SUPPORT_DIR, f".realesrgan_{variant}_version")
    with open(sidecar, "w", encoding="utf-8") as f:
        f.write(MODEL_VERSION)
    print(f"[convert] installed locally: {dest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=["x2", "x4"], required=True,
                        help="Which Real-ESRGAN variant to build")
    parser.add_argument("--install", action="store_true",
                        help="Also copy the compiled model into Application Support")
    args = parser.parse_args()

    compiled, _ = convert(args.variant)
    if args.install:
        install_locally(compiled, args.variant)

    print()
    print("Next steps:")
    print("  1. Upload the .zip in build/ to the matching GitHub Release:")
    print(f"     realesrgan-{args.variant}-{MODEL_VERSION}")
    print("  2. Verify the URL in UpscaleModelManager.Variant.downloadURL matches.")


if __name__ == "__main__":
    main()
