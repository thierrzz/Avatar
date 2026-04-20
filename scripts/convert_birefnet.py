#!/usr/bin/env python3
"""
Convert BiRefNet to CoreML for Avatar.

Developer build tool — run this once to produce a compiled .mlmodelc that
can be zipped and hosted for in-app download by end users.

Uses the official BiRefNet PyTorch model from HuggingFace (ZhengPeng7/BiRefNet)
and converts it via torch.jit.trace → coremltools → xcrun coremlcompiler.

Usage:
    # Install dependencies:
    pip3 install coremltools torch transformers timm einops kornia

    # Convert and create zip for hosting:
    python3 scripts/convert_birefnet.py

    # Also install locally (for development):
    python3 scripts/convert_birefnet.py --install

Output:
    build/BiRefNet.mlmodelc/       — compiled model (ready for the app)
    build/BiRefNet.mlmodelc.zip    — ready for upload/hosting
"""

import os
import sys
import shutil
import subprocess

# ─── Configuration ────────────────────────────────────────────────────────────

MODEL_NAME = "BiRefNet"
# Portrait fine-tune of BiRefNet — trained specifically on human subjects so
# face/hair/shoulder edges hold up far better than the generic DIS checkpoint
# we shipped in v1.
HF_MODEL_ID = "ZhengPeng7/BiRefNet-portrait"
INPUT_SIZE = 1024  # BiRefNet expects 1024x1024 input

# Keep in sync with ModelManager.currentModelVersion — written as a sidecar
# next to the installed .mlmodelc so the app can detect stale builds and
# re-download on launch.
MODEL_VERSION = "v2"
VERSION_SIDECAR_NAME = ".model_version"

# ImageNet normalization stats BiRefNet was trained with. We bake these into
# the traced graph so CoreML sees the pre-processing the model actually expects
# — the v1 conversion missed this and was the primary cause of leaky mattes.
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]
BUILD_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build")

# App Support directory where Avatar looks for the model.
APP_SUPPORT_DIR = os.path.expanduser(
    "~/Library/Application Support/Avatar/Models"
)


def check_dependencies():
    """Verify that required Python packages are installed."""
    missing = []
    for pkg in ["coremltools", "torch", "transformers", "timm", "einops", "kornia"]:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)

    if missing:
        print(f"\n  Ontbrekende packages: {', '.join(missing)}")
        print(f"  Installeer met: pip3 install {' '.join(missing)}\n")
        sys.exit(1)


def convert_to_coreml(output_dir: str):
    """Load BiRefNet from HuggingFace, trace, and convert to CoreML."""
    import coremltools as ct
    import torch
    import torch.nn.functional as F
    from transformers import AutoModelForImageSegmentation

    # Stap 1: Load the official BiRefNet model from HuggingFace
    print("  Stap 1/4: BiRefNet laden van HuggingFace...")
    model = AutoModelForImageSegmentation.from_pretrained(
        HF_MODEL_ID, trust_remote_code=True
    )
    model.eval()
    n_params = sum(p.numel() for p in model.parameters())
    print(f"  Model geladen ({n_params/1e6:.0f}M parameters)")

    # Stap 2: Replace DeformableConv2d with regular Conv2d
    # (coremltools doesn't support torchvision::deform_conv2d)
    print("  Stap 2/4: DeformableConv2d -> Conv2d (CoreML compatibiliteit)...")
    replaced = 0
    for name, module in model.named_modules():
        if type(module).__name__ == "DeformableConv2d":
            def make_regular_forward(mod):
                def regular_forward(x):
                    return F.conv2d(x, mod.regular_conv.weight, mod.regular_conv.bias,
                                   stride=mod.stride, padding=mod.padding)
                return regular_forward
            module.forward = make_regular_forward(module)
            replaced += 1
    print(f"  {replaced} modules vervangen")

    # Stap 3: Wrap model (add sigmoid) and trace
    print("  Stap 3/4: Model tracen...")

    class BiRefNetWrapper(torch.nn.Module):
        def __init__(self, base_model):
            super().__init__()
            self.model = base_model
            # Register ImageNet stats as buffers so they're frozen into the
            # traced graph. CoreML divides incoming pixels by 255 (see the
            # ImageType `scale` below); the wrapper then applies the per-
            # channel mean subtraction and std division PyTorch training used.
            self.register_buffer(
                "mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1)
            )
            self.register_buffer(
                "std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1)
            )

        def forward(self, x):
            # x arrives in 0-1 RGB (CoreML scale=1/255 applied upstream).
            x = (x - self.mean) / self.std
            outputs = self.model(x)
            # BiRefNet returns a list; take the final (finest) prediction
            pred = outputs[-1][-1] if isinstance(outputs[-1], (list, tuple)) else outputs[-1]
            return torch.sigmoid(pred)

    wrapper = BiRefNetWrapper(model)
    wrapper.eval()

    example_input = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_input)
    print("  Trace OK")

    # Stap 4: Convert PyTorch → CoreML
    print("  Stap 4/4: PyTorch -> CoreML (dit duurt een paar minuten)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input",
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                scale=1.0 / 255.0,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )

    # Set model metadata
    mlmodel.author = "ZhengPeng7 (BiRefNet-portrait) — converted for Avatar"
    mlmodel.license = "MIT"
    mlmodel.short_description = (
        "BiRefNet-portrait: portrait fine-tune of BiRefNet for high-"
        "resolution person segmentation with ImageNet normalization baked "
        "into the graph. Alpha matte for hair and fine edge detail."
    )

    mlpackage_path = os.path.join(output_dir, f"{MODEL_NAME}.mlpackage")
    if os.path.exists(mlpackage_path):
        shutil.rmtree(mlpackage_path)

    mlmodel.save(mlpackage_path)

    # Log input/output names for debugging
    spec = mlmodel.get_spec()
    for inp in spec.description.input:
        print(f"  CoreML input: {inp.name}")
    for out in spec.description.output:
        print(f"  CoreML output: {out.name}")

    print(f"  Saved: {mlpackage_path}")
    return mlpackage_path


def compile_model(mlpackage_path: str, output_dir: str):
    """Compile .mlpackage to .mlmodelc using xcrun coremlcompiler."""
    print("  Compileren .mlpackage -> .mlmodelc...")

    compiled_path = os.path.join(output_dir, f"{MODEL_NAME}.mlmodelc")
    if os.path.exists(compiled_path):
        shutil.rmtree(compiled_path)

    # Use xcrun coremlcompiler (same compiler Xcode uses)
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlpackage_path, output_dir],
        capture_output=True, text=True
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
    print(f"  Gecompileerd model ({size_mb:.0f} MB): {compiled_path}")
    return compiled_path


def create_zip(compiled_path: str, output_dir: str):
    """Create a zip archive of the compiled model for hosting."""
    zip_base = os.path.join(output_dir, f"{MODEL_NAME}.mlmodelc")
    zip_path = shutil.make_archive(
        zip_base, "zip", output_dir, f"{MODEL_NAME}.mlmodelc"
    )
    size_mb = os.path.getsize(zip_path) / (1024 * 1024)
    print(f"  ZIP archief ({size_mb:.0f} MB): {zip_path}")
    return zip_path


def install_to_app(compiled_path: str):
    """Copy the compiled model to Avatar's Application Support."""
    dest = os.path.join(APP_SUPPORT_DIR, f"{MODEL_NAME}.mlmodelc")
    os.makedirs(APP_SUPPORT_DIR, exist_ok=True)

    if os.path.exists(dest):
        shutil.rmtree(dest)

    shutil.copytree(compiled_path, dest)

    # Stamp the install with the model version so the app doesn't treat this
    # as a stale v1 install and wipe it on next launch.
    sidecar_path = os.path.join(APP_SUPPORT_DIR, VERSION_SIDECAR_NAME)
    with open(sidecar_path, "w") as f:
        f.write(MODEL_VERSION)

    print(f"  Model geinstalleerd in: {dest}")
    print(f"  Versie-sidecar: {sidecar_path} ({MODEL_VERSION})")
    print("  Avatar zal het model automatisch detecteren.")


def main():
    print("=" * 60)
    print("  BiRefNet -> CoreML Conversie voor Avatar")
    print("=" * 60)
    print()

    install_locally = "--install" in sys.argv

    # 1. Check dependencies
    print("[1/4] Dependencies controleren...")
    check_dependencies()
    print("  OK")

    # 2. Convert to CoreML (downloads model from HuggingFace automatically)
    os.makedirs(BUILD_DIR, exist_ok=True)
    print(f"\n[2/4] Converteren naar CoreML...")
    mlpackage_path = convert_to_coreml(BUILD_DIR)

    # 3. Compile
    print(f"\n[3/4] Compileren...")
    compiled_path = compile_model(mlpackage_path, BUILD_DIR)

    # 4. Create zip for hosting
    print(f"\n[4/4] ZIP archief maken...")
    zip_path = create_zip(compiled_path, BUILD_DIR)

    # Done
    print()
    print("-" * 60)
    print(f"  Conversie voltooid!")
    print()
    print(f"  Gecompileerd model: {compiled_path}")
    print(f"  ZIP voor hosting:   {zip_path}")
    print()

    if install_locally:
        print("  --install flag gedetecteerd, lokaal installeren...")
        install_to_app(compiled_path)
    else:
        print("  Upload de ZIP naar een publieke URL (bijv. GitHub Release)")
        print("  en vul de URL in bij ModelManager.modelDownloadURL in de app.")
        print()
        print("  Tip: gebruik --install om ook lokaal te installeren:")
        print(f"  python3 scripts/convert_birefnet.py --install")

    print()


if __name__ == "__main__":
    main()
