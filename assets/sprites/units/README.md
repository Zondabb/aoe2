# Unit sprite direction mapping

Exported walk sheets use **5 authored facings** plus **horizontal flip** for the other three (classic AoE layout).

## Authored rows / `dir_N` animations

| Index | Facing | Notes |
|------:|--------|-------|
| 0 | South (+Z) | Authored |
| 1 | Southwest | Authored; SE uses this + `flip_h` |
| 2 | West (-X) | Authored; East uses this + `flip_h` |
| 3 | Northwest | Authored; NE uses this + `flip_h` |
| 4 | North (-Z) | Authored |

Sheet packing is sequential: frame index = `direction * frames_per_direction + step`, then placed into the PNG grid (`cols` × `rows` from the sidecar JSON).

## Runtime quantization

`SpriteCatalog.quantize_xz_facing(velocity)` maps XZ motion to 8 sectors around +Z (South), then to `{dir, flip}`:

| Sector | World | Result |
|-------:|-------|--------|
| 0 | S | dir 0 |
| 1 | SE | dir 1 + flip |
| 2 | E | dir 2 + flip |
| 3 | NE | dir 3 + flip |
| 4 | N | dir 4 |
| 5 | NW | dir 3 |
| 6 | W | dir 2 |
| 7 | SW | dir 1 |

Unit nodes stay unrotated on Y; facing is presentation-only via `AnimatedSprite3D` animation + `flip_h`. Hotspots in JSON are **cell-relative** (centered X, bottom-aligned Y inside each sheet cell) and drive the billboard offset so feet stay on the ground peg.
