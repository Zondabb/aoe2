"""Semantic player masks, packing alignment, and composite RGB contributions."""

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from export_sprites import composite_hotspot_images, pack_sheet
from player_color import composite_player_masks, export_player_palette, pack_masks, save_player_mask
from regenerate_all import scale2x
from slp import decode_with_player_masks


def one_row_slp(width, commands):
    return (struct.pack('<4si24s', b'2.0N', 1, b'')
            + struct.pack('<IIIIiiii', 68, 64, 0, 0, width, 1, 2, 0)
            + struct.pack('<HHI', 0, 0, 72) + bytes(commands) + bytes([0x0F]))


def composite(images, masks):
    parts = [(image, 0, 0, 0, 0) for image in images]
    canvas, x, y = composite_hotspot_images(parts)
    return canvas, composite_player_masks(parts, masks, canvas, x, y)


class PlayerColorTests(unittest.TestCase):
    def test_only_player_opcodes_mark_pixels(self):
        palette = [(i, i, i, 255) for i in range(256)]
        # Literal index 53 equals player 3 shade 5. Fill also uses that literal.
        # These must stay ordinary, while 0x06 draw and 0x0A fill get marks.
        data = one_row_slp(9, [0x04, 53, 0x17, 53, 0x26, 5, 15,
                              0x2A, 0, 0x05, 0x1B, 0x04, 0])
        frames, metas, masks = decode_with_player_masks(data, palette, player=3)
        self.assertEqual(metas[0].hotspot_x, 2)
        self.assertEqual(list(masks[0].getdata()),
                         [(0, 0, 0), (0, 0, 0), (6, 255, 0), (16, 255, 0),
                          (1, 255, 0), (1, 255, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0)])
        self.assertEqual(frames[0].getpixel((6, 0)), (0, 0, 0, 0))
        self.assertEqual(frames[0].getpixel((7, 0)), (0, 0, 0, 100))
        self.assertEqual(frames[0].getpixel((8, 0)), (0, 0, 0, 255))

    def test_packing_uses_base_padding_and_empty_cells(self):
        frames = [Image.new('RGBA', size, (5, 6, 7, 255)) for size in ((4, 3), (1, 1), (2, 2))]
        masks = [Image.new('RGB', frame.size, (index + 1, 255, 0)) for index, frame in enumerate(frames)]
        sheet, cols, rows, width, height, pads = pack_sheet(frames)
        mask_sheet = pack_masks(masks, sheet.size, cols, width, height, pads)
        self.assertEqual(mask_sheet.size, (8, 6))
        self.assertEqual(mask_sheet.getpixel((5, 2)), (2, 255, 0))
        self.assertEqual(mask_sheet.getpixel((4, 2)), (0, 0, 0))
        self.assertEqual(mask_sheet.getpixel((7, 5)), (0, 0, 0))

    def test_shadow_attenuates_and_opaque_artwork_clears(self):
        base = Image.new('RGBA', (3, 1), (100, 80, 60, 255))
        mask = Image.new('RGB', (3, 1), (6, 255, 0))
        front = Image.new('RGBA', (3, 1))
        front.putdata([(0, 0, 0, 100), (100, 80, 60, 255), (0, 0, 0, 0)])
        canvas, result = composite([base, front], [mask, Image.new('RGB', (3, 1))])
        self.assertEqual(list(result.getdata()), [(6, 155, 0), (0, 0, 0), (6, 255, 0)])
        recolored = np.asarray(canvas).astype(float)
        recolored[..., :3] += np.asarray(result)[..., 1, None] / 255 * np.array([80, -40, 20])
        target = Image.new('RGBA', (3, 1), (180, 40, 80, 255))
        target.alpha_composite(front)
        np.testing.assert_allclose(recolored, np.asarray(target), atol=1)

    def test_multiple_shadows_and_front_player_override(self):
        color = Image.new('RGBA', (1, 1), (100, 80, 60, 255))
        shadow = Image.new('RGBA', (1, 1), (0, 0, 0, 100))
        marked = Image.new('RGB', (1, 1), (6, 255, 0))
        empty = Image.new('RGB', (1, 1))
        _, mask = composite([shadow, color, shadow, shadow], [empty, marked, empty, empty])
        self.assertEqual(mask.getpixel((0, 0)), (6, 94, 0))
        _, mask = composite([color, shadow, color], [marked, empty, Image.new('RGB', (1, 1), (9, 255, 0))])
        self.assertEqual(mask.getpixel((0, 0)), (9, 255, 0))

    def test_ambiguous_translucent_player_shades_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'translucent player shades'):
            composite([Image.new('RGBA', (1, 1), (1, 2, 3, 255)),
                       Image.new('RGBA', (1, 1), (4, 5, 6, 100))],
                      [Image.new('RGB', (1, 1), (1, 255, 0)),
                       Image.new('RGB', (1, 1), (2, 255, 0))])

    def test_shared_palette_rows_and_metadata(self):
        palette = [(i, 255 - i, i // 2, 255) for i in range(256)]
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            path = export_player_palette(out, palette)
            with Image.open(path) as image:
                self.assertEqual(image.size, (16, 8))
                self.assertEqual(image.getpixel((15, 7)), palette[143][:3])
                self.assertEqual(image.getpixel((0, 0)), palette[16][:3])
            meta = save_player_mask(Image.new('RGB', (1, 1), (16, 255, 0)), out, 'unit', 3)
            self.assertEqual(meta['source_player'], 3)
            self.assertEqual(meta['encoding'], 'index_weight_rg8')
            self.assertEqual(meta['mask'], 'unit_player_mask.png')
            self.assertEqual(save_player_mask(Image.new('RGB', (1, 1)), out, 'empty', 3), {'mode': 'none'})
            self.assertFalse((out / 'empty_player_mask.png').exists())
            self.assertIn('process/fix_alpha_border=false', Path(str(path) + '.import').read_text())

    def test_preview_mask_follows_artwork_edge_choices(self):
        image = Image.new('RGBA', (3, 3), (0, 0, 0, 0))
        image.putpixel((1, 0), (100, 100, 100, 255))
        image.putpixel((0, 1), (100, 100, 100, 255))
        mask = Image.new('RGB', image.size)
        mask.putpixel((1, 0), (6, 255, 0))
        mask.putpixel((0, 1), (6, 255, 0))
        scaled_image, scaled_mask = scale2x(image), scale2x(image, mask)
        self.assertEqual(scaled_image.getpixel((2, 2)), (100, 100, 100, 255))
        self.assertEqual(scaled_mask.getpixel((2, 2)), (6, 255, 0))


if __name__ == '__main__':
    unittest.main()
