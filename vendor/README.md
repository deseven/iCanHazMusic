# Vendored decoders

macOS can't open WavPack or Monkey's Audio (APE) files at all, so the app compiles their reference decoders in. They
are plain SwiftPM targets of this package (`Package.swift`), built with the app: no package dependencies, no dylibs.

| Directory | What | Version | License | Module |
|---|---|---|---|---|
| `wavpack/` | libwavpack, the decoder part (C) | 5.9.0 | BSD-3-Clause (`wavpack/COPYING`) | `CWavPack` |
| `monkeys-audio/` | Monkey's Audio SDK (C++) + our C wrapper | 13.43 | BSD-3-Clause (`monkeys-audio/License.txt`) | `CMonkeysAudio` |

Exact sources (git commit, zip hash) are in `UPSTREAM`.

## Rules

- **Never edit the upstream files.** Everything of ours is outside them: `monkeys-audio/shim/` (and the target settings
  in `Package.swift`). A warning in upstream code is switched off for its target, not patched.
- **Update only with `./update.sh`**: change the version (and for Monkey's Audio the zip's sha256) at its top, run it,
  build, run the tests (`tests/VendoredDecoderTests.swift` and the format fixtures), update the table above. The diff
  then shows upstream's changes and nothing else.
- What is copied is listed in `update.sh`, with why the rest is left out.
- Only `Core` code that decodes or describes these formats imports the modules (see `dev-docs/extra-formats-support.md`).
- The license texts go into the app bundle (`build.sh`: `Contents/Resources/ThirdPartyLicenses`).

## WavPack

From the [GitHub repository](https://github.com/dbry/WavPack), at its release tag. Only the decoder: no encoder, no
assembly (the x86 asm isn't used on arm64 anyway), no worker threads. DSD (decoded to PCM) and legacy (< 4.0) files are
in. Swift calls its C API (`wavpack.h`) directly; files are read through a `WavpackStreamReader64` of ours.

## Monkey's Audio

From the [official SDK zip](https://monkeysaudio.com/developers.html): there is no official repository (the GitHub
ones are old unofficial ports, of 3.99 and 4.11, with the pre-BSD license). Everything but the console tool, the DLL,
the Windows projects and the SIMD filters of PowerPC/RISC-V; the encoder stays in because the SDK's `All.h` always enables
it (it is dead code for us).

`shim/` is ours: a C interface (`ichm_ape.h`) so Swift needs no C++ interop, which

- reads the file through a callback of the caller (`ichm_ape_reader`), never through the SDK's own file I/O,
- catches every C++ exception at the boundary,
- hands out interleaved little-endian integer samples (or floats, `is_float`), as documented in the header.

`-Wno-inconsistent-missing-override` is set for this target: the SDK's `StdLibFileIO.h` (compiled because `MACLib.cpp`
refers to it, not used) lacks `override`.
