# 37 Heaps Mandala

A visionOS mixed-reality game where you complete a traditional Tibetan Buddhist **37-heap mandala offering** on a **stacked-ring** plate (four rising levels), matching the physical offering-set structure.

## Requirements

- Xcode 26+ with visionOS 26 SDK
- Apple Vision Pro Simulator (or device)

## Open & Run

```bash
cd /Users/kevinwoods/Downloads/visionOS/Mandala37Heaps
open Mandala37Heaps.xcodeproj
```

Select the **Apple Vision Pro** simulator and press Run, or build from the CLI:

```bash
xcodebuild \
  -project Mandala37Heaps.xcodeproj \
  -scheme Mandala37Heaps \
  -destination 'platform=visionOS Simulator,id=AE97F89F-0818-4B5F-BED7-5FF0EF33626F' \
  -derivedDataPath build \
  build

xcrun simctl install AE97F89F-0818-4B5F-BED7-5FF0EF33626F \
  build/Build/Products/Debug-xrsimulator/Mandala37Heaps.app

xcrun simctl launch AE97F89F-0818-4B5F-BED7-5FF0EF33626F \
  com.kevinwoods.Mandala37Heaps -autoEnter
```

The `-autoEnter` debug argument opens the immersive mandala automatically after launch.

## How to play

1. Tap **Begin Offering** (or launch with `-autoEnter`).
2. Start on the **base plate + largest ring** (Level 1 · Universe: Meru, continents, subcontinents).
3. **Guided mode**: tap the cyan beacon for the next heap in traditional order.
4. When a level is full, the **next smaller ring** settles onto the grain and unlocks the next heaps (Treasures → Goddesses → Celestial).
5. Completing all 37 places the **top ornament** and celebration bloom.
6. **Free mode** only allows placement on currently unlocked rings.
7. Ornament controls: mode, **Reset**, **Exit**.

## Tier map

| Level | Ring | Heaps |
|------|------|-------|
| 1 | Largest | 1–13 Meru, continents, subcontinents |
| 2 | Second | 14–25 treasures, royal emblems, vase |
| 3 | Third | 26–33 offering goddesses |
| 4 | Smallest | 34–37 sun, moon, parasol, victory banner |

## Notes

- All geometry is procedural RealityKit meshes — no external USDZ assets required.
- Bundle ID: `com.kevinwoods.Mandala37Heaps`
- Deployment target: visionOS 26.0
