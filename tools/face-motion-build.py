#!/usr/bin/env python3
"""The deterministic motion build for the portrait drawer (specs/face.md,
rules 51-55).

Two jobs, both pure image arithmetic — no generative step, per rule 1's
deterministic-tools clause:

1. Motion-region masks. The plate family is flat, so secondary motion needs
   declared regions: each mask is a feathered alpha PNG registered 1:1 to
   the 420x420 plate, drawn from hand-measured polygons over the approved
   resting frame (the drill ringlets, the chest ribbon knot, the two white
   pom-pom ornaments). Alpha tapers to zero toward each region's anatomical
   attachment so motion amplitude dies where the part joins the body, and
   every mask carries a background margin wider than the renderer's motion
   clamp so no seam of doubled artwork can open (rule 53).

2. Mouth normalisation (rule 55). The 2026-08-30 `open` and `wide` patches
   were dramatically larger and right-heavy.  The first normaliser also
   scaled the *erasure* of the plate's resting frown, exposing that old line
   beside the new contour.  Every patch is now rebuilt over one harmonically
   inpainted clean-mouth plate.  Only its changed contour is scaled, its
   measured horizontal centre is placed on the lip anchor, and the full old
   frown stays erased.  Originals are preserved, measurements recorded.

The manifest gains: mask assets, a `motion` section (regions with pivot,
mode, spring constants, drive gains, clamps), per-viseme `extent`, a
top-level `mouth.anchor`, and a recomputed revision. Everything this script
writes is recorded in motion-build-record.json in the drawer.

Idempotent: mouth sources are read from the preserved copy once one exists,
so a re-run regenerates identical bytes rather than shrinking twice.
"""

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter
import numpy as np

DRAWER = Path(os.environ.get(
    "DESKCRAB_PORTRAIT_DIR",
    str(Path.home() / "Beatrice/face/portraits")))
LIVING = DRAWER / "living"
PRESERVED = DRAWER / "preserved-2026-08-31-pre-motion"
SIZE = (420, 420)

# ---- the measured geometry (plate coordinates, 420x420) -------------------
# Hand-measured over living/face-resting.png at 2x zoom, 2026-08-31.

RINGLET_LEFT = [(55, 88), (105, 95), (118, 140), (112, 200), (100, 260),
                (88, 320), (76, 385), (60, 412), (25, 412), (8, 340),
                (4, 240), (8, 150), (25, 100)]
RINGLET_RIGHT = [(350, 85), (395, 105), (408, 180), (405, 260), (398, 330),
                 (388, 395), (370, 415), (340, 415), (330, 350), (322, 270),
                 (318, 190), (325, 120)]
RIBBON = ("ellipse", (223, 295), (30, 45))       # the chest ribbon knot+tails
POM_LEFT = ("ellipse", (196, 352), (24, 23))     # white pom-pom, viewer left
POM_RIGHT = ("ellipse", (238, 360), (24, 23))    # white pom-pom, viewer right

# Feathered edge, and a vertical taper toward each attachment.
FEATHER = 5.0
TAPERS = {   # alpha *= smoothstep between these y values
    # No taper on the pom-poms: a bob region translates as one rigid piece,
    # and a gradient across the ball would smear it; the feathered fabric
    # margin (mask radius > ball radius > clamp) hides the seam instead.
    "motion-ringlet-left": (150, 230),
    "motion-ringlet-right": (150, 230),
    "motion-ribbon": (262, 292),
}

REGIONS = [
    # id, mask asset, mode, pivot, stiffness, damping, drive gains, clamps
    {"id": "ringlet-left", "asset": "motion-ringlet-left",
     "mode": "pendulum", "pivot": [88, 130],
     "stiffness": 26.0, "damping": 3.4,
     "drive": {"sway": 1.35, "agitation": 1.0}, "max_deg": 1.2},
    {"id": "ringlet-right", "asset": "motion-ringlet-right",
     "mode": "pendulum", "pivot": [350, 130],
     "stiffness": 22.0, "damping": 3.0,
     "drive": {"sway": 1.25, "agitation": 1.0}, "max_deg": 1.2},
    {"id": "ribbon", "asset": "motion-ribbon",
     "mode": "pendulum", "pivot": [223, 262],
     "stiffness": 40.0, "damping": 5.0,
     "drive": {"sway": 0.8, "agitation": 0.6}, "max_deg": 0.9},
    {"id": "pom-left", "asset": "motion-pom-left",
     "mode": "bob", "pivot": [196, 332],
     "stiffness": 60.0, "damping": 4.6,
     "drive": {"breath": 1.0, "sway": 0.5, "agitation": 1.0}, "max_px": 2.6},
    {"id": "pom-right", "asset": "motion-pom-right",
     "mode": "bob", "pivot": [238, 340],
     "stiffness": 52.0, "damping": 4.2,
     "drive": {"breath": 1.1, "sway": 0.5, "agitation": 1.0}, "max_px": 2.6},
]

ROOT = {   # rule 51's grounded idle, stated once and read by every renderer
    "pivot": [210, 420],           # the ground: bottom centre of the frame
    "sway_deg": 0.55, "sway_period": 7.6,
    "shift_px": 1.8, "shift_period": 11.0,
    "breath_scale": 0.0045, "breath_period": 4.2,
}

# Mouth normalisation: viseme -> scale about the lip anchor. Chosen from the
# measured changed-region extents so the family lands in one band
# (slight 17x3, teeth 17x5, round 16x11, wide 25x8 -> 20x6, open 24x16 -> 18x12).
MOUTH_SCALE = {"open": 0.75, "wide": 0.80, "round": 0.93,
               "slight": 1.0, "teeth": 1.0}
ANCHOR = (27, 16)   # centre of the resting lip line inside the 50x34 rect


def smoothstep(a, b, x):
    t = np.clip((x - a) / float(b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def build_mask(name, shape):
    im = Image.new("L", SIZE, 0)
    d = ImageDraw.Draw(im)
    if isinstance(shape, list):
        d.polygon(shape, fill=255)
    else:
        _, (cx, cy), (rx, ry) = shape
        d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=255)
    im = im.filter(ImageFilter.GaussianBlur(FEATHER))
    a = np.asarray(im).astype(np.float32) / 255.0
    if name in TAPERS:
        y0, y1 = TAPERS[name]
        ys = np.arange(SIZE[1], dtype=np.float32)[:, None]
        a *= smoothstep(y0, y1, np.broadcast_to(ys, a.shape))
    out = np.zeros((SIZE[1], SIZE[0], 4), dtype=np.uint8)
    out[..., 0:3] = 255
    out[..., 3] = (a * 255).astype(np.uint8)
    path = LIVING / (name + ".png")
    Image.fromarray(out, "RGBA").save(path)
    return path


def clean_mouth_plate(plate_rect):
    """Remove the resting contour without flattening the face's skin.

    The mouth is wholly inside this measured box.  Solving the discrete
    Laplace equation within it continues the surrounding skin gradient from
    the unchanged boundary, with no clone seam or generated pixels.
    """
    out = plate_rect.astype(np.float64).copy()
    mask = np.zeros(out.shape[:2], dtype=bool)
    mask[12:23, 15:39] = True
    for _ in range(700):
        prev = out.copy()
        avg = (np.roll(prev, 1, 0) + np.roll(prev, -1, 0)
               + np.roll(prev, 1, 1) + np.roll(prev, -1, 1)) / 4.0
        out[mask] = avg[mask]
    return np.clip(np.round(out), 0, 255).astype(np.uint8)


def normalise_mouth(viseme, scale, plate_rect, clean_rect,
                    src_path, dst_path):
    """Scale the patch's changed region about the lip anchor and lay it back
    over stable plate skin. Returns (before_extent, after_extent)."""
    patch = np.asarray(Image.open(src_path).convert("RGB")).astype(np.int16)
    base = plate_rect.astype(np.int16)
    d = np.abs(patch - base).sum(axis=2)
    changed = d > 12
    ys, xs = np.where(changed)
    before = [int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)]
    h, w = d.shape
    # Feathered mask of the changed content.
    m = Image.fromarray((changed * 255).astype(np.uint8), "L") \
        .filter(ImageFilter.MaxFilter(3)) \
        .filter(ImageFilter.GaussianBlur(1.2))
    # Scale patch and mask about the anchor, supersampled for quality.
    SS = 4
    ax, ay = ANCHOR
    # Centre the actual changed contour, rather than trusting the old patch's
    # placement.  Difference weights retain shading and anti-aliasing while
    # ignoring unaltered skin.  This moves the right-heavy AI/EE family five
    # native pixels left and leaves already-centred shapes essentially still.
    yy, xx = np.indices(d.shape)
    weight = np.where(d > 12, d, 0).astype(np.float64)
    centre_x = float((xx * weight).sum() / weight.sum())
    shift_x = int(round(ax - centre_x))

    def rescale(img, resample):
        big = img.resize((w * SS, h * SS), resample)
        sw, sh = int(round(w * SS * scale)), int(round(h * SS * scale))
        small = big.resize((sw, sh), resample)
        canvas = Image.new(img.mode, (w * SS, h * SS), 0)
        ox = int(round(ax * SS - ax * SS * scale + shift_x * SS))
        oy = int(round(ay * SS - ay * SS * scale))
        canvas.paste(small, (ox, oy))
        return canvas.resize((w, h), Image.LANCZOS)

    patch_img = Image.fromarray(patch.astype(np.uint8), "RGB")
    scaled_patch = np.asarray(rescale(patch_img, Image.LANCZOS)).astype(np.float32)
    scaled_mask = np.asarray(rescale(m, Image.BILINEAR)).astype(np.float32) / 255.0
    # The background is the clean-mouth plate, never the original resting
    # frown.  Scaling the changed pixels may shrink the old erasure, but there
    # is therefore no line underneath it to leak back into view.
    out = clean_rect.astype(np.float32) * (1 - scaled_mask[..., None]) \
        + scaled_patch * scaled_mask[..., None]
    out8 = np.clip(np.round(out), 0, 255).astype(np.uint8)
    Image.fromarray(out8, "RGB").save(dst_path)
    d2 = np.abs(out8.astype(np.int16) - clean_rect.astype(np.int16)).sum(axis=2)
    ys2, xs2 = np.where(d2 > 12)
    after = [int(xs2.max() - xs2.min() + 1), int(ys2.max() - ys2.min() + 1)]
    # Rule 9: the border ring stays plate skin.
    ring = np.ones_like(d2, bool)
    ring[2:-2, 2:-2] = False
    assert int(d2[ring].max()) <= 12, f"{viseme}: border no longer plate skin"
    return before, after, round(centre_x, 3), shift_x


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    manifest_path = DRAWER / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    rect = manifest["visemes"]["open"]["rect"]

    # Preserve originals once; a re-run reads sources from the preservation.
    PRESERVED.mkdir(exist_ok=True)
    for v in MOUTH_SCALE:
        keep = PRESERVED / f"mouth-{v}.png"
        if not keep.exists():
            shutil.copyfile(LIVING / f"mouth-{v}.png", keep)
    keep_manifest = PRESERVED / "manifest.json"
    if not keep_manifest.exists():
        shutil.copyfile(manifest_path, keep_manifest)

    plate = np.asarray(
        Image.open(LIVING / "face-resting.png").convert("RGB"))
    plate_rect = plate[rect[1]:rect[3], rect[0]:rect[2]]
    clean_rect = clean_mouth_plate(plate_rect)

    record = {"date": "2026-08-31", "root": ROOT, "regions": REGIONS,
              "feather_px": FEATHER, "tapers": TAPERS,
              "mouth": {"anchor": list(ANCHOR), "scales": MOUTH_SCALE,
                        "extents": {}}}

    # 1. masks
    shapes = {"motion-ringlet-left": RINGLET_LEFT,
              "motion-ringlet-right": RINGLET_RIGHT,
              "motion-ribbon": RIBBON,
              "motion-pom-left": POM_LEFT,
              "motion-pom-right": POM_RIGHT}
    for name, shape in shapes.items():
        p = build_mask(name, shape)
        manifest["assets"][name] = {"file": f"living/{name}.png",
                                    "sha256": sha(p)}

    # 2. mouths
    for v, scale in MOUTH_SCALE.items():
        dst = LIVING / f"mouth-{v}.png"
        before, after, centre_before, shift_x = normalise_mouth(
            v, scale, plate_rect, clean_rect,
            PRESERVED / f"mouth-{v}.png", dst)
        manifest["assets"][f"mouth-{v}"]["sha256"] = sha(dst)
        manifest["visemes"][v]["extent"] = after
        record["mouth"]["extents"][v] = {
            "before": before, "after": after,
            "centre_before": centre_before, "shift_x": shift_x}
    record["mouth"]["clean_plate_box"] = [15, 12, 39, 23]
    manifest["mouth"] = {"anchor": list(ANCHOR), "rest_extent": [17, 4]}

    manifest["motion"] = {"root": ROOT, "regions": REGIONS}
    rev = hashlib.sha256("\n".join(
        f"{k}:{v['sha256']}" for k, v in
        sorted(manifest["assets"].items())).encode()).hexdigest()[:12]
    manifest["revision"] = rev
    manifest_path.write_text(json.dumps(manifest, indent=1, sort_keys=True))
    (DRAWER / "motion-build-record.json").write_text(
        json.dumps(record, indent=1))

    # A review strip of the normalised family beside the plate's own mouth.
    patches = [Image.fromarray(plate_rect.astype(np.uint8))] + [
        Image.open(LIVING / f"mouth-{v}.png")
        for v in ["slight", "teeth", "round", "wide", "open"]]
    strip = Image.new("RGB", (len(patches) * 160, 120), (20, 20, 20))
    for i, p in enumerate(patches):
        strip.paste(p.resize((150, 102), Image.NEAREST), (5 + i * 160, 9))
    strip.save(DRAWER / "mouth-normalised-review-2026-08-31.png")
    print(f"revision {rev}")
    for v, e in record["mouth"]["extents"].items():
        print(f"  {v}: {e['before']} -> {e['after']} "
              f"centre={e['centre_before']} shift={e['shift_x']}")


if __name__ == "__main__":
    sys.exit(main())
