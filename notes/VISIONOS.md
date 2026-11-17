# visionOS evaluation

Branch `visionos/engine-compile`. Everything here was checked with Xcode 27.2 on synthetic inputs: no game files, no Vision Pro.
Nothing has run a game on visionOS yet.

## What is in place

| Piece | Where | State |
|---|---|---|
| Host and iOS front end compile for visionOS | patches 0062, 0063 | 269 C and Objective-C files and the Swift sources compile; iOS unchanged |
| `DM_SDK=xros` in the build tools | patches 0064, 0065 | the one-game app, the game framework and the prepared project build for visionOS |
| Shell UI | `frontend-ios` (`VisionCompat.swift`, `Package.swift`) | builds for visionOS 27.1, runs in the Apple Vision Pro simulator |
| Shell app | `frontend-ios/Shell/build_shell.sh` | `DM_SDK=xros` links `DmShell.app` for visionOS |
| visionOS shader libraries | patch 0066 (`dm/ios/tools/xros_metal.py`) | the wrapper is tested on a sample shader, never on a game's shaders |

`DM_SDK` is `iphoneos` by default: without it every script does what it did.

## Known limits on visionOS

- No MetalFX temporal scaler in the SDK: a game that asks for DLSS is scaled bilinearly (one line in the log says so).
- No simulator: neither the visionOS nor the iOS simulator SDK has Metal 4, so the engine only runs on a device.
- No pipeline archive unless `DM_PSO_GPUS` names the GPUs (the profiles list iPhone GPUs).
- No tap feedback for the touch controls, no screen brightness, no external display.
- Unknown until a device run: the memory limit and whether the Increased Memory Limit entitlement is honoured, BC texture support, performance.

## Checks that need no game

```sh
python3 tools/engine.py sync
brew bundle --file=Brewfile
python3 -m venv .venv && .venv/bin/python -m pip install fonttools

# the one-game app, linked for visionOS with stand-in modules (a new, empty output folder each time)
DM_SDK=xros GAME=0100000000010000 python3 engine/dm/ios/tools/build_smoke.py --output /tmp/smoke-xros

# the visionOS shader wrapper
(cd engine && python3 -m unittest dm/ios/tests/test_xros_metal.py)

# the shell libraries
xcodebuild -scheme ShellHost -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO   # in frontend-ios/
```

## iPad

Nothing changed for iOS. Build and install as [BUILDING.md](../BUILDING.md) and the README describe (the Mac launcher, or
`engine/scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys>`).

## Vision Pro, with a game: what is still manual

`engine/scripts/build_ipa_from_nsp.py` is not wired for visionOS: it extracts and rewrites the game as always, but its shader step
builds iPhone libraries and it does not pass `DM_SDK` on. The cheapest first test needs none of this: install the normal iPad
build on the Vision Pro from Xcode ("Designed for iPad" destination) and see whether the game starts.

For a native visionOS build, after a normal run of the NSP script has made the work folder:

1. Build the shader libraries for visionOS into a folder of their own, with the same arguments and environment the NSP script
   gave `dmsh_build.py` (they are in the work folder's `logs/dmsh_build.log`), through the wrapper:
   `IOSOUT=<work>/sh/xros python3 engine/dm/ios/tools/xros_metal.py engine/dm/gfx/tools/dmsh_build.py <same arguments>`
   (a Vulkan or OpenGL game: `xros_metal.py engine/dm/gfx/tools/vk_shaders.py … --ios <work>/sh/xros`).
2. Run `build_ipa.sh` with `DM_SDK=xros`, `MSL_IOS=<work>/sh/xros` and otherwise the environment the NSP script gave it
   (`logs/build_ipa.log`, `logs/prepare_xcode.log`): `--prepare-xcode` writes a visionOS Xcode project to sign and run on the device.

Step 1 has never been run on a real game. Wiring both steps into the NSP script is the next piece of work, and needs a game dump
to test against.

## Patch headers

Patches 0062 to 0066 are `fork-only` and their `Issue:` line says none has been filed. File one and put its number there before
this goes to LNPANDY/NX2Apple.
