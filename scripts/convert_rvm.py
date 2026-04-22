#!/usr/bin/env python3
"""
Convert RobustVideoMatting (RVM) to CoreML for Avatar.

v5 of the "advanced matte" model. Replaces BiRefNet because:
  1. BiRefNet v4 won't compile on current Apple Silicon — ANE rejects an
     oversized conv tile (KMEM 103680 > 65536) and MPS rejects a dtype.
  2. RVM is purpose-built for portrait hair matting and is ~15 MB (vs
     ~500 MB for BiRefNet) thanks to its MobileNetV3 backbone.
  3. RVM predicts both alpha (`pha`) and unmixed foreground (`fgr`) —
     the `fgr` output solves the "translucent subject over coloured
     background" failure mode we hit at v3. For this initial drop-in
     we only consume `pha` in Swift; `fgr` wiring is a follow-up.

The compiled model is named `BiRefNet.mlmodelc` (not `RVM.mlmodelc`) so
that ModelManager's existing `compiledModelName` constant keeps working.
Rename to `AdvancedMatte.mlmodelc` is tracked as follow-up work.

Developer build tool — run this once to produce a compiled .mlmodelc
that can be zipped and hosted for in-app download by end users.

Usage:
    # Install dependencies:
    pip3 install coremltools torch torchvision

    # Convert and create zip for hosting:
    python3 scripts/convert_rvm.py

    # Also install locally (for development):
    python3 scripts/convert_rvm.py --install

Output:
    build/BiRefNet.mlmodelc/       — compiled model (ready for the app)
    build/BiRefNet.mlmodelc.zip    — ready for upload/hosting

Hosting:
    Upload the .zip to the GitHub release tagged `rvm-v5`:
        https://github.com/thierrzz/Avatar/releases/tag/rvm-v5
    ModelManager.modelDownloadURL resolves to this URL automatically
    once currentModelVersion is bumped to "v5".
"""

import os
import sys
import shutil
import subprocess
import urllib.request

# ─── Configuration ────────────────────────────────────────────────────────────

# Compiled-model name kept as "BiRefNet" so ModelManager's compiledModelName
# constant works without a rename. The *contents* are RVM.
COMPILED_NAME = "BiRefNet"

# RVM weights (PyTorch checkpoint) — MobileNetV3 variant. Hosted by the
# author on GitHub releases. We cache into build/ to avoid re-downloading.
# ResNet50 variant is ~35 MB and more accurate but not as ANE-friendly.
RVM_WEIGHTS_URL = "https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3.pth"
RVM_WEIGHTS_FILENAME = "rvm_mobilenetv3.pth"

# Input shape: RVM takes a 3-channel RGB frame at (B, C, H, W).
# 1024×576 is the widescreen variant — matches the resize in
# ImageProcessor.birefnetLift and fits ANE tile limits cleanly.
INPUT_HEIGHT = 576
INPUT_WIDTH = 1024

# RVM's downsample_ratio — ByteDance recommends 0.375 for 1080p-class
# portraits. Baked into the traced graph so the Swift side only feeds
# the source frame.
DOWNSAMPLE_RATIO = 0.375

# Keep in sync with ModelManager.currentModelVersion — written as a
# sidecar next to the installed .mlmodelc so the app can detect stale
# builds and re-download on launch.
MODEL_VERSION = "v5"
VERSION_SIDECAR_NAME = ".model_version"

BUILD_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build"
)

APP_SUPPORT_DIR = os.path.expanduser(
    "~/Library/Application Support/Avatar/Models"
)


def check_dependencies():
    """Verify that required Python packages are installed."""
    missing = []
    for pkg in ["coremltools", "torch", "torchvision"]:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)

    if missing:
        print(f"\n  Ontbrekende packages: {', '.join(missing)}")
        print(f"  Installeer met: pip3 install {' '.join(missing)}\n")
        sys.exit(1)


def download_weights(dest_dir: str) -> str:
    """Download the RVM MobileNetV3 checkpoint if not already cached."""
    os.makedirs(dest_dir, exist_ok=True)
    path = os.path.join(dest_dir, RVM_WEIGHTS_FILENAME)
    if os.path.exists(path) and os.path.getsize(path) > 1_000_000:
        print(f"  Weights reeds aanwezig: {path}")
        return path

    print(f"  RVM weights downloaden van: {RVM_WEIGHTS_URL}")
    urllib.request.urlretrieve(RVM_WEIGHTS_URL, path)
    size_mb = os.path.getsize(path) / (1024 * 1024)
    print(f"  Download gereed ({size_mb:.1f} MB): {path}")
    return path


def _build_rvm_model(weights_path: str):
    """
    Construct the RVM MobileNetV3 model and load the checkpoint.

    RVM's source tree defines the model architecture in a small Python
    package. Rather than vendoring the whole library, we import it on
    demand — user can `pip install git+https://github.com/PeterL1n/RobustVideoMatting`
    or clone it beside this repo. We prefer the pip route and fall back
    to a cloned ./RobustVideoMatting directory.
    """
    import torch

    try:
        # Preferred: the RVM author's package if user has installed it.
        from model import MattingNetwork  # type: ignore
    except ImportError:
        # Fallback: expect a sibling checkout of the repo.
        repo_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "RobustVideoMatting",
        )
        if not os.path.isdir(repo_dir):
            print(
                "\n  RVM source tree niet gevonden. Kies een van:\n"
                "    1) pip3 install git+https://github.com/PeterL1n/RobustVideoMatting\n"
                f"    2) git clone https://github.com/PeterL1n/RobustVideoMatting {repo_dir}\n"
            )
            sys.exit(1)
        sys.path.insert(0, repo_dir)
        from model import MattingNetwork  # type: ignore

    model = MattingNetwork(variant="mobilenetv3")
    state = torch.load(weights_path, map_location="cpu")
    model.load_state_dict(state)
    model.eval()
    return model


def convert_to_coreml(weights_path: str, output_dir: str) -> str:
    """Trace RVM and convert to CoreML mlprogram."""
    import coremltools as ct
    import torch

    print("  Stap 1/3: RVM laden...")
    rvm = _build_rvm_model(weights_path)
    n_params = sum(p.numel() for p in rvm.parameters())
    print(f"  Model geladen ({n_params/1e6:.1f}M parameters)")

    print("  Stap 2/3: Model tracen...")

    class RVMWrapper(torch.nn.Module):
        """
        Adapts RVM's video API to a single-image CoreML graph.

        RVM's forward signature is:
            fgr, pha, r1o, r2o, r3o, r4o = model(src, r1, r2, r3, r4, downsample_ratio)

        For a still image we pass zero-initialized recurrent state and
        ignore the output state. The CoreML model only exposes `fgr`
        and `pha`. Downsample ratio is baked into the graph.

        Input channel layout: RVM expects RGB in [0, 1]. CoreML's
        ImageType applies scale=1/255 upstream, so this wrapper receives
        a [B, 3, H, W] tensor already in [0, 1] — no mean/std needed.
        """

        def __init__(self, base_model, downsample_ratio: float):
            super().__init__()
            self.model = base_model
            # Keep as a plain Python float, NOT a registered buffer. RVM's
            # internal `_interpolate` passes scale_factor straight into
            # F.interpolate, which only accepts a float in torch 2.x — a
            # Tensor buffer would fail the dispatch. The float is baked
            # into the traced graph as a constant either way.
            self.downsample_ratio = float(downsample_ratio)

        def forward(self, x):
            # Omit the recurrent state args — RVM's ConvGRU.forward
            # self-initializes a zero tensor of the correct shape when
            # h is None (see RobustVideoMatting/model/decoder.py). Passing
            # zeros ourselves gets the shape wrong because the hidden size
            # differs per decoder level.
            fgr, pha, *_ = self.model(
                x, downsample_ratio=self.downsample_ratio
            )
            return fgr, pha

    wrapper = RVMWrapper(rvm, DOWNSAMPLE_RATIO)
    wrapper.eval()

    example = torch.rand(1, 3, INPUT_HEIGHT, INPUT_WIDTH)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    print("  Trace OK")

    print("  Stap 3/3: PyTorch -> CoreML (dit duurt even)...")
    mlmodel = ct.convert(
        traced,
        # Single image input, named "input" to match Swift's current
        # feature-provider key (ImageProcessor.birefnetLift uses "input").
        inputs=[
            ct.ImageType(
                name="input",
                shape=(1, 3, INPUT_HEIGHT, INPUT_WIDTH),
                scale=1.0 / 255.0,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[
            ct.TensorType(name="fgr"),
            ct.TensorType(name="pha"),
        ],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )

    mlmodel.author = "PeterL1n (RobustVideoMatting) — converted for Avatar"
    mlmodel.license = "GPL-3.0"
    mlmodel.short_description = (
        "RobustVideoMatting (MobileNetV3): portrait matting producing "
        "alpha (pha) and unmixed foreground (fgr) for hair-strand quality. "
        "Recurrent state zeroed for single-image inference."
    )

    mlpackage_path = os.path.join(output_dir, f"{COMPILED_NAME}.mlpackage")
    if os.path.exists(mlpackage_path):
        shutil.rmtree(mlpackage_path)
    mlmodel.save(mlpackage_path)

    spec = mlmodel.get_spec()
    for inp in spec.description.input:
        print(f"  CoreML input:  {inp.name}")
    for out in spec.description.output:
        print(f"  CoreML output: {out.name}")

    print(f"  Saved: {mlpackage_path}")
    return mlpackage_path


def compile_model(mlpackage_path: str, output_dir: str) -> str:
    """Compile .mlpackage to .mlmodelc using xcrun coremlcompiler."""
    print("  Compileren .mlpackage -> .mlmodelc...")

    compiled_path = os.path.join(output_dir, f"{COMPILED_NAME}.mlmodelc")
    if os.path.exists(compiled_path):
        shutil.rmtree(compiled_path)

    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlpackage_path, output_dir],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"  FOUT: coremlcompiler exit {result.returncode}")
        print(f"  stderr: {result.stderr}")
        sys.exit(1)

    if not os.path.exists(compiled_path):
        print(f"  FOUT: Compiled model niet gevonden op: {compiled_path}")
        sys.exit(1)

    size_mb = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, fns in os.walk(compiled_path)
        for f in fns
    ) / (1024 * 1024)
    print(f"  Gecompileerd model ({size_mb:.1f} MB): {compiled_path}")
    return compiled_path


def create_zip(compiled_path: str, output_dir: str) -> str:
    """Create a zip archive of the compiled model for hosting."""
    zip_base = os.path.join(output_dir, f"{COMPILED_NAME}.mlmodelc")
    zip_path = shutil.make_archive(
        zip_base, "zip", output_dir, f"{COMPILED_NAME}.mlmodelc"
    )
    size_mb = os.path.getsize(zip_path) / (1024 * 1024)
    print(f"  ZIP archief ({size_mb:.1f} MB): {zip_path}")
    return zip_path


def install_to_app(compiled_path: str) -> None:
    """Copy the compiled model to Avatar's Application Support."""
    dest = os.path.join(APP_SUPPORT_DIR, f"{COMPILED_NAME}.mlmodelc")
    os.makedirs(APP_SUPPORT_DIR, exist_ok=True)

    if os.path.exists(dest):
        shutil.rmtree(dest)

    shutil.copytree(compiled_path, dest)

    sidecar_path = os.path.join(APP_SUPPORT_DIR, VERSION_SIDECAR_NAME)
    with open(sidecar_path, "w") as f:
        f.write(MODEL_VERSION)

    print(f"  Model geinstalleerd in: {dest}")
    print(f"  Versie-sidecar: {sidecar_path} ({MODEL_VERSION})")
    print("  Avatar zal het model automatisch detecteren.")


def main():
    print("=" * 60)
    print("  RVM -> CoreML Conversie voor Avatar (v5)")
    print("=" * 60)
    print()

    install_locally = "--install" in sys.argv

    print("[1/5] Dependencies controleren...")
    check_dependencies()
    print("  OK")

    os.makedirs(BUILD_DIR, exist_ok=True)

    print(f"\n[2/5] RVM weights ophalen...")
    weights_path = download_weights(BUILD_DIR)

    print(f"\n[3/5] Converteren naar CoreML...")
    mlpackage_path = convert_to_coreml(weights_path, BUILD_DIR)

    print(f"\n[4/5] Compileren...")
    compiled_path = compile_model(mlpackage_path, BUILD_DIR)

    print(f"\n[5/5] ZIP archief maken...")
    zip_path = create_zip(compiled_path, BUILD_DIR)

    print()
    print("-" * 60)
    print(f"  Conversie voltooid!")
    print()
    print(f"  Gecompileerd model: {compiled_path}")
    print(f"  ZIP voor hosting:   {zip_path}")
    print()
    print(f"  Upload de ZIP als asset op GitHub release `rvm-{MODEL_VERSION}`.")
    print(f"  ModelManager.modelDownloadURL resolvet automatisch naar die URL.")
    print()

    if install_locally:
        print("  --install flag gedetecteerd, lokaal installeren...")
        install_to_app(compiled_path)
    else:
        print("  Tip: gebruik --install om ook lokaal te installeren:")
        print(f"  python3 scripts/convert_rvm.py --install")

    print()


if __name__ == "__main__":
    main()
