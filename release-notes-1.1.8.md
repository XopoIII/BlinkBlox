A housekeeping release. A generated module differs from 1.1.7's by the version in its header: it
runs the same code, the wire does not change, and nothing needs recompiling.

### Changed

- **`--from quicknet` records QuickNet v0.4.0-beta definitions** (commit `edba9a2`, the head of main
  the day it was released; its tag points at v0.3.5's source). `Data.Font` and `Data.Ray` have no
  equivalent and become `unknown`, as `Rect` does, and so does `Data.custom`: the game's own encoder
  and decoder are functions a schema cannot hold. Each is named in the checklist.
- **`--from warp` records Warp 1.1.0-pre8 schemas.** Its new `vector3f32` and `vector2f32` become
  `vector` and `Vector2`; they stopped the conversion as names the converter did not know.
- **The benchmarks fetch QuickNet v0.4.0-beta and Warp 1.1.0-pre8.** QuickNet 0.4.0 drops a packet
  over 50,000 bytes and the events past the hundredth in one, for every event, so `download.luau`
  lifts both as it lifts Packet's and Warp's limits. On one machine, side by side, QuickNet 0.4.0
  fires `Entities` in 13.7 ms native and 31.1 interpreted, from 0.3.5's 18.0 and 40.1, and decodes it
  in 28.2 and 51.4, from 32.1 and 61.0; BlinkBlox's are 4.7 and 12.9 there. Warp pre8 times as pre7
  did, and now frames its unreliable packets too: 2 bytes more each, 1,050 bytes a frame for
  `SelfState` to 50 players, from 950. The published tables are still 0.3.5's and pre7's.
- **The CLI archives are built on LuneBlox 0.10.17**, up from 0.10.16, and the tests and benchmarks
  run on it. Its Luau, fast flags and mlua are 0.10.16's; the suite and the goldens pass on it
  unchanged.

