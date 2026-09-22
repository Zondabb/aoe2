"""Lossless player-index data and palette output shared by all SLP exporters."""

from pathlib import Path
from typing import Sequence

import numpy as np
from PIL import Image

from palette import Color


def pack_masks(masks, sheet_size, cols, frame_w, frame_h, pads):
    """Use the base sheet's exact cells and padding, including empty cells."""
    sheet = Image.new("RGB", sheet_size)
    for i, mask in enumerate(masks):
        sheet.paste(mask, ((i % cols) * frame_w + pads[i]["x"],
                           (i // cols) * frame_h + pads[i]["y"]))
    return sheet


def export_player_palette(out_dir: Path, palette: Sequence[Color]) -> Path:
    if len(palette) < 144:
        raise ValueError("player palette requires entries 16 through 143")
    if any(color[3] != 255 for color in palette[16:144]):
        raise ValueError("shared player palette requires opaque colors")
    image = Image.new("RGB", (16, 8))
    image.putdata([palette[player * 16 + shade][:3]
                   for player in range(1, 9) for shade in range(16)])
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "player_palette.png"
    image.save(path)
    write_data_texture_import(path)
    return path


def write_data_texture_import(path: Path) -> None:
    """Godot must preserve byte indices/weights, even for very dark pixels."""
    import_path = Path(str(path) + ".import")
    if import_path.exists():
        text = import_path.read_text(encoding="utf-8")
        # Preserve Godot's remap/cache paths after it has performed an import.
        import re
        for key, value in (("compress/mode", "0"), ("mipmaps/generate", "false"),
                           ("process/fix_alpha_border", "false"),
                           ("process/premult_alpha", "false")):
            text = re.sub(r"(?m)^" + re.escape(key) + r"=.*$", key + "=" + value, text)
    else:
        text = ('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n'
                '[params]\n\ncompress/mode=0\ncompress/high_quality=false\n'
                'compress/lossy_quality=0.7\ncompress/hdr_compression=1\n'
                'compress/normal_map=0\ncompress/channel_pack=0\n'
                'mipmaps/generate=false\nmipmaps/limit=-1\n'
                'roughness/mode=0\nroughness/src_normal=""\n'
                'process/fix_alpha_border=false\nprocess/premult_alpha=false\n'
                'process/normal_map_invert_y=false\nprocess/hdr_as_srgb=false\n'
                'process/hdr_clamp_exposure=false\nprocess/size_limit=0\n'
                'detect_3d/compress_to=0\n')
    import_path.write_text(text, encoding="utf-8")


def save_player_mask(mask: Image.Image, cat_dir: Path, key: str, player: int):
    """Return additive metadata; uncolored sheets need no mask file."""
    if not mask.getchannel("R").getbbox():
        return {"mode": "none"}
    path = cat_dir / f"{key}_player_mask.png"
    mask.save(path)
    write_data_texture_import(path)
    return {"mode": "indexed", "mask": path.name,
            "palette": "res://assets/sprites/player_palette.png",
            "source_player": max(1, min(8, player)), "encoding": "index_weight_rg8"}


def composite_player_masks(parts, masks, canvas: Image.Image, origin_x, origin_y):
    """Composite semantic masks in the same back-to-front layer order as RGBA.

    A shadow over a player pixel reduces the recolorable RGB contribution.
    Ordinary opaque artwork clears it. Mixing different translucent player
    shades cannot be represented by one index, so explicitly reject that case.
    Keep floating point contributions until the final 8-bit encoding.
    """
    if len(parts) != len(masks):
        raise ValueError("one player mask is required for every composite layer")
    shape = (canvas.height, canvas.width)
    indices = np.zeros(shape, dtype=np.uint8)
    contribution = np.zeros(shape, dtype=np.float64)
    alpha = np.zeros(shape, dtype=np.float64)
    for (im, hx, hy, ox, oy), mask in zip(parts, masks):
        if im.size != mask.size:
            raise ValueError("player mask size differs from its composite layer")
        x, y = origin_x - hx + ox, origin_y - hy + oy
        region = np.s_[y:y + im.height, x:x + im.width]
        data = np.asarray(mask.convert("RGB"))
        src_alpha = np.asarray(im.getchannel("A"), dtype=np.float64) / 255.0
        src_index = data[..., 0]
        src_contribution = (data[..., 1].astype(np.float64) / 255.0) * src_alpha
        src_contribution = np.where(src_index > 0, src_contribution, 0.0)
        dst_contribution = contribution[region] * (1.0 - src_alpha)
        mixing = ((src_contribution > 0) & (dst_contribution > 0)
                  & (src_index != indices[region]))
        if np.any(mixing):
            raise ValueError("overlapping translucent player shades require more than one mask index")
        combined = src_contribution + dst_contribution
        indices[region] = np.where(src_contribution > 0, src_index,
                                   np.where(combined > 0, indices[region], 0))
        contribution[region] = combined
        alpha[region] = src_alpha + alpha[region] * (1.0 - src_alpha)
    weights = np.zeros(shape, dtype=np.float64)
    np.divide(contribution, alpha, out=weights, where=alpha > 0)
    result = np.zeros((*shape, 3), dtype=np.uint8)
    result[..., 0] = indices
    result[..., 1] = np.rint(np.clip(weights, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(result)
