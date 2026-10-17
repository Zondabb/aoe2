"""Farm exports sample repeating terrain rather than shrinking the whole atlas."""
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from farm_terrain import project_farm_terrain


class FarmTerrainTests(unittest.TestCase):
    def test_projection_samples_only_the_reference_calibrated_plot(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "farm.png"
            texture = Image.new("RGBA", (512, 512), "magenta")
            texture.paste(Image.new("RGBA", (154, 154), "green"), (0, 0))
            texture.save(source)
            image, hotspot, meta = project_farm_terrain(source)
            self.assertEqual(image.size, (288, 144))
            self.assertEqual(hotspot, (144, 72))
            self.assertEqual(meta["footprint"], [3, 3])
            self.assertEqual(meta["source_sample_rect"], [0, 0, 154, 154])
            self.assertTrue(meta["ground_terrain"])
            colors = {color for count, color in image.getcolors(image.width * image.height)}
            self.assertIn((0, 128, 0, 255), colors)
            self.assertNotIn((255, 0, 255, 255), colors)
            for corner in ((0, 0), (287, 0), (0, 143), (287, 143)):
                self.assertEqual(image.getpixel(corner)[3], 0)

    def test_rows_follow_the_reference_up_right_direction(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "rows.png"
            texture = Image.new("RGBA", (512, 512))
            for row in range(154):
                texture.paste((row, row, row, 255), (0, row, 154, row + 1))
            texture.save(source)
            image, _, _ = project_farm_terrain(source)
            self.assertEqual(image.getpixel((120, 78)), image.getpixel((144, 66)))
            self.assertNotEqual(image.getpixel((120, 78)), image.getpixel((120, 90)))

    def test_both_original_stages_share_geometry_density_and_anchor(self):
        root = Path(__file__).resolve().parents[3]
        import json
        complete = json.loads((root / "assets/sprites/civilizations/farm_ground.json").read_text())
        foundation = json.loads((root / "assets/sprites/foundations/farm_construction_ground.json").read_text())
        for key in ("frame_w", "frame_h", "hotspots", "ground_terrain", "footprint",
                    "row_direction", "source_sample_rect", "includes_shadow"):
            self.assertEqual(complete[key], foundation[key], key)
        self.assertNotEqual(complete["source_sha256"], foundation["source_sha256"])


if __name__ == "__main__":
    unittest.main()
