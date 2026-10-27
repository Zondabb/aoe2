# Original AoE2 audio export

This copies a small, audited set of the original **Age of Empires II HD** PCM
sounds into `assets/audio/original/`. It does not synthesize replacements,
re-encode the recordings, or copy the rest of the game installation. The game
loads the checked-in WAV files through `assets/audio/manifest.json` and does not
need the original installation or Python at runtime.

From the repository root, with Python 3.10 or newer:

```powershell
python tools/audio_export/export_audio.py --resources "<AoE2 HD installation>/resources"
python -m unittest discover -s tools/audio_export/tests -v
```

No Python packages are required. The resource argument is deliberately explicit;
no personal installation paths or local configuration are stored here. The
exporter accepts both HD unpacked `_common/drs/sounds/` and `interface/` folders
and equivalent packed `sounds.drs` / `interface.drs` files. Source hashes must
match the audited set. A mismatched or missing source fails before writing
output. `--output` can generate a verification copy in another folder.

## Manifest

`catalog.json` is the reviewed source mapping. `manifest.json` is generated.
Every runtime event contains `files` (Godot `res://` paths), `volume_db`,
`cooldown` (seconds), and `category` (`ui`, `voice`, or `world`). Aliases in the
catalog are expanded by the exporter, so runtime code needs no alias resolver.
The `streams` table records original filenames, DRS IDs, SHA-256 hashes, PCM
format, duration, and mapping evidence. Files reused by several events are
exported only once. Output WAV bytes exactly match the originals.

Voice events use Chinese (`civilization_id=6`) and Teuton (`civilization_id=4`)
recordings. The limited variant set deliberately keeps the assets small.
Villager actions: `select`, `move`, `attack`, `build`, `gather_food`,
`gather_wood`, and `gather_mine`. Military actions: `select`, `move`, `attack`.
There is no dedicated stop sound: `stop` reuses the original move acknowledgment.
Generic villager `gather` uses the original woodcutter acknowledgment.

The manifest's `voice_profiles` maps 17 current catalog definition IDs to their
original unit sound roles. Unlisted units retain the villager/military fallback.
Each specialized role provides `select`, `move`, `attack`, and `stop` for both
civilizations. Original command cues supply move/attack/stop; only the monk
recordings in this table vary by civilization. The other roles share their
original nonverbal recordings without duplicating WAV files.

| Voice role | Current unit lines | DAT selection / command sounds |
| --- | --- | --- |
| cavalry | Knight, Cavalier, Paladin, Light Cavalry | 325 / 326 |
| scout | Scout Cavalry | 325 / 474 |
| camel | Camel, Heavy Camel | 430 / 326 |
| cavalry_archer | Cavalry Archer, Heavy Cavalry Archer | 325 / 415 |
| monk | Monk | 423 / 424 |
| mangonel | Mangonel, Onager, Siege Onager | 489 / 476 |
| scorpion | Scorpion, Heavy Scorpion | 490 / 476 |
| trebuchet | Trebuchet | 291 / 484 |
| trade_cart | Trade Cart | 305 / 306 |

These pairs were checked against both Chinese and Teuton DAT unit records
using each catalog entry's `source_id`. Rams and Bombard Cannon use the original
generic military selection/command sounds (420 / 422), so they remain unlisted.

Building selection events use the building's DAT selection sound; those same
records use the same sound for construction completion. `building_select` and
`construction_complete` use the house cue as the generic fallback. Gate
selection uses the original gate opening sound (`gateo.wav`, ID 5326) because
the obsolete gate selection reference 5062 is absent from the HD sound folder.
`age_up` uses the original `resdone.wav` research completion cue.

## Mapping evidence

Unit voices, building cues, worker actions, weapon sounds and deaths were read
from the original `_common/dat/empires2_x1_p1.dat` via the existing local
openage reader (`openage/convert/value_object/read/media/datfile/sound.py` and
`unit.py`). The compressed source DAT SHA-256 is:

```text
28b50786d62cc956679bf56b42b272ec04eb93642268e997484dbc63bb24e6cb
```

`catalog.json` preserves each sound table index, civilization and original
filename. Relevant sound indexes include 294 (male deaths), 308 (hammer), 309
(farm), 310 (chop), 311 (ore), 314 (arrow), 317 (villager ready), 329 (sword),
337 (military ready), and 471 (food gathering).

Building destruction and siege firing are traced through the original unit's
graphic references, including the per-angle graphic attack sound properties:

| Event | Original DAT reference | Sound index |
| --- | --- | --- |
| building_destroyed | Town Center unit 109 -> dying graphic 40 | 323 (`exp1.wav`, `exp2.wav`) |
| siege_fire_stone | Mangonel unit 280 -> attack graphic 979 | 107 (`MANGO.wav`, `mango1.wav`) |
| siege_fire_cannon | Bombard Cannon unit 36 -> attack graphic 654 | 385 (`can1.wav`, `can2.wav`) |
| siege_fire_trebuchet | Unpacked Trebuchet unit 42 -> attack graphic 1174 | 290 (`trebfir1.wav`, `trebfir2.wav`) |
| siege_fire_onager | Onager unit 588 -> attack graphic 3159 | 466 (`sonar1.wav`, `sonar2.wav`) |
| siege_fire_bolt | Scorpion unit 279 -> attack graphic 1070 | 384 (`balista2.wav`, `balista3.wav`) |

Stone is the Mangonel fallback; Onager and Trebuchet retain separate keys
because their original firing sounds differ despite sharing stone projectiles.

Interface IDs are hardcoded outside the DAT. They were verified by reading the
original HD executable's sound registration calls and embedded WAV filenames;
the executable was not executed or modified. The audited `AoK HD.exe` SHA-256 is:

```text
cbd10d81b93601ffb26773d250b7478969da92d70792a40ae423294202e14650
```

Registration code begins near file offset `0x22aab0`; it pushes a numerical
DRS resource ID followed by the original filename pointer. For example, the
`cantdo.wav` pointer at `0x22ac32` is preceded by `68 7f c4 00 00` (push 50303).
Verified mappings used here:

| ID | Original filename | Event |
| --- | --- | --- |
| 50301 | button2.wav | click |
| 50303 | cantdo.wav | error |
| 50305 | resdone.wav | age_up |
| 50315 | atakwarn.wav | attack_warning |
| 50316 | enemwarn.wav | civilian_attack_warning |
| 50320 | won.wav | victory |
| 50321 | lost.wav | defeat |
| 50357 | townbell.wav | town_bell |

The result screen at executable file offset `0x2c17c8` selects `won.wav` /
`lost.wav` from pointers `0x009d57bc` / `0x009d57c4` and calculates the sound
ID as 50320 + the lost-state flag. This confirms the victory and defeat mapping
independently of their recording durations. The alarm and bell mappings also
agree with openage's `doc/media/sound.md` and
`doc/reverse_engineering/game_mechanics/attacking_alarm.md`.

These original game resources retain their original ownership, consistent with
the existing original sprite assets in this project.
