# Asian feudal Town Center layout

The original `resources/_common/dat/empires2_x1_p1.dat` (version `VER 5.7`)
contains composite graphic **3347**. Its `graphic_deltas` specify these pixel
offsets; they are not visual estimates:

| Graphic ID | SLP ID | X | Y | Y relative to main |
| --- | --- | --- | --- | --- |
| 441 | 897 | 0 | 0 | 48 |
| 437 | 893 | 0 | 0 | 48 |
| 445 | 901 | 0 | -48 | 0 |
| 3251 | 3606 | 0 | 0 | 48 |
| 5480 | 4622 | 0 | 0 | 48 |
| 3247 | 3602 | 0 | 24 | 72 |
| 5476 | 4618 | 0 | 24 | 72 |
| 3243 | 3598 | 0 | 48 | 96 |
| 5472 | 4614 | 0 | 48 | 96 |

SLP 897 is referenced but absent from this HD installation's graphics/interface/
loose SLP directories. It is a `UNIT_LOW` layer; it is not the cause of the eave
seam, which disappears when the existing roof layers use the correct offsets.

The exporter uses a main-hotspot origin. With 96x48 tiles, the equivalent tile
offsets are `(1, 1)` for base/shadow, `(1.5, 1.5)` for middle supports, and
`(2, 2)` for roofs. The former additional `(0.1, 0.1)` became 5 pixels after
rounding, shifting every annex downward relative to the main building.

Evidence was read using the local openage Python DAT parser, specifically
`openage/convert/value_object/read/media/datfile/empiresdat.py` and
`graphic.py` (`GraphicDelta.offset_x/offset_y`). This verifies original game
data, not a running openage renderer. The full DAT also parsed to its exact
5,634,431-byte end, and unit 621's Dark Age preview confirms the same offsets.
