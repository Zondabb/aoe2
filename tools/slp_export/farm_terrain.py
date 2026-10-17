"""Project original HD farm terrain with reference-calibrated rows and scale."""
import hashlib

from PIL import Image


FOOTPRINT = (3, 3)
# The reference has ~10-11px between plants along a 96x48 terrain grid.
# A 154px sample retains that spacing on the native three-tile diamond. This
# is calibrated from the game screenshots, rather than the demo's sim scale.
SOURCE_SAMPLE_SIZE = 154
TILE_WIDTH, TILE_HEIGHT = 96, 48


def project_farm_terrain(source):
    width = height = SOURCE_SAMPLE_SIZE
    with Image.open(source) as original:
        patch = original.convert("RGBA").crop((0, 0, width, height))
    frame_w, frame_h = FOOTPRINT[0] * TILE_WIDTH, FOOTPRINT[1] * TILE_HEIGHT
    # HD terrain orientation is rotated relative to the SLP tile axes. This
    # inverse maps rows toward screen-up-right while keeping stalks upright.
    ratio = width / (frame_w * 0.5)
    image = patch.transform((frame_w, frame_h), Image.Transform.AFFINE,
                            (ratio * 0.5, -ratio, width * 0.5,
                             ratio * 0.5, ratio, -height * 0.5),
                            Image.Resampling.NEAREST)
    details = dict(
        ground_terrain=True, footprint=list(FOOTPRINT), includes_shadow=False,
        source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
        source_sample_rect=[0, 0, width, height],
        reference_calibrated=True, row_direction="screen_up_right",
    )
    return image, (frame_w // 2, frame_h // 2), details
