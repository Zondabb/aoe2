"""SLP color zero is black; transparency belongs to drawing commands."""

import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from palette import load_pal
from slp import decode_with_meta
from export_sprites import composite_hotspot_images, pack_sheet


class TransparencyTests(unittest.TestCase):
    def test_black_and_transparent_commands_through_export(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.pal'
            path.write_text('JASC-PAL\n0100\n2\n0 0 0\n255 255 255\n')
            palette = load_pal(path)
            self.assertEqual(palette[0], (0, 0, 0, 255))
            self.assertEqual(load_pal(path, transparent_index=0)[0][3], 0)

        # One row: black literal, black fill, transparent skip, shadow, end.
        data = struct.pack('<4si24s', b'2.0N', 1, b'')
        data += struct.pack('<IIIIiiii', 68, 64, 0, 0, 4, 1, 0, 0)
        data += struct.pack('<HHI', 0, 0, 72)
        data += bytes([0x04, 0, 0x17, 0, 0x05, 0x1B, 0x0F])
        frames, _ = decode_with_meta(data, palette)
        expected = [(0, 0, 0, 255), (0, 0, 0, 255),
                    (0, 0, 0, 0), (0, 0, 0, 100)]
        self.assertEqual([frames[0].getpixel((x, 0)) for x in range(4)], expected)
        sheet, *_ = pack_sheet(frames)
        canvas, _, _ = composite_hotspot_images([(frames[0], 0, 0, 0, 0)])
        self.assertEqual(sheet.tobytes(), frames[0].tobytes())
        self.assertEqual(canvas.tobytes(), frames[0].tobytes())


if __name__ == '__main__':
    unittest.main()
