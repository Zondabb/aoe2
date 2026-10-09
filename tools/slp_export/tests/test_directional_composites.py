"""Composite SLP delta layers keep their direction, anchor and player mask."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from original_graphics import GraphicExporter, ANIMATION_COMPOSITING_VERSION


ROOT = Path(__file__).resolve().parents[3]


def graphic(gid, frames_per_direction, deltas=()):
    return SimpleNamespace(graphic_id=gid, slp_id=gid, name=f'test_{gid}',
                           frame_count=frames_per_direction, frame_rate=0.1,
                           layer='UNIT', graphic_deltas=list(deltas))


class DirectionalCompositeTests(unittest.TestCase):
    def export_fixture(self, directory, main_fpd, delta_fpd):
        delta = SimpleNamespace(graphic_id=2, offset_x=1, offset_y=0)
        graphics = [graphic(1, main_fpd, [delta]), graphic(2, delta_fpd)]
        exporter = GraphicExporter(SimpleNamespace(graphics=graphics), ROOT, directory)
        def read_slp(gid):
            fpd = main_fpd if gid == 1 else delta_fpd
            frames, masks, metadata = [], [], []
            for direction in range(5):
                for step in range(fpd):
                    frames.append(Image.new('RGBA', (1, 1), (30 * direction, 40 * step, gid, 255)))
                    masks.append(Image.new('RGB', (1, 1), (direction + 1, 255, 0)))
                    metadata.append(SimpleNamespace(hotspot_x=0, hotspot_y=0))
            return frames, metadata, masks, '', ''
        exporter.slp = read_slp
        exporter.export(1, animation=True)
        return exporter

    def check_fixture(self, main_fpd, delta_fpd):
        with tempfile.TemporaryDirectory(prefix='.test-composite-', dir=ROOT) as temporary:
            directory = Path(temporary)
            self.export_fixture(directory, main_fpd, delta_fpd)
            meta = json.loads((directory/'g1_anim.json').read_text())
            with Image.open(directory/'g1_anim.png') as image, Image.open(directory/'g1_anim_player_mask.png') as mask:
                fpd = max(main_fpd, delta_fpd)
                self.assertEqual(meta['directions'], 5)
                self.assertEqual(meta['frames_per_direction'], fpd)
                self.assertEqual(meta['frame_count'], 5 * fpd)
                self.assertAlmostEqual(meta['animation_duration'], 0.1 * fpd)
                for direction in range(5):
                    for step in range(fpd):
                        index = direction * fpd + step
                        x, y = (index % meta['cols']) * meta['frame_w'], (index // meta['cols']) * meta['frame_h']
                        self.assertEqual(image.getpixel((x, y)), (30 * direction, 40 * (step % main_fpd), 1, 255))
                        self.assertEqual(image.getpixel((x + 1, y)), (30 * direction, 40 * (step % delta_fpd), 2, 255))
                        self.assertEqual(mask.getpixel((x + 1, y)), (direction + 1, 255, 0))
                        self.assertEqual(meta['hotspots'][index], {'x': 0, 'y': 0})

    def test_animated_body_with_static_directional_chassis(self):
        self.check_fixture(3, 1)

    def test_static_body_with_animated_directional_delta(self):
        self.check_fixture(1, 3)

    def test_two_animated_cycles_never_cross_direction(self):
        self.check_fixture(4, 2)

    def test_old_composite_cache_is_regenerated_then_reused(self):
        with tempfile.TemporaryDirectory(prefix='.test-composite-', dir=ROOT) as temporary:
            directory = Path(temporary)
            self.export_fixture(directory, 3, 1)
            metadata_path = directory/'g1_anim.json'
            metadata = json.loads(metadata_path.read_text())
            metadata.pop('animation_compositing_version')
            metadata_path.write_text(json.dumps(metadata))
            exporter = self.export_fixture(directory, 3, 1)
            self.assertFalse(exporter.report[-1]['cached'])
            self.assertEqual(json.loads(metadata_path.read_text())['animation_compositing_version'], ANIMATION_COMPOSITING_VERSION)
            exporter = self.export_fixture(directory, 3, 1)
            self.assertTrue(exporter.report[-1]['cached'])


if __name__ == '__main__':
    unittest.main()
