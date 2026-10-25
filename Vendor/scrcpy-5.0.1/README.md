# AndroidUse ordered-touch scrcpy server patch

This directory contains the minimal Android server-side delta used by the
native AndroidUse client. The unmodified upstream inputs are kept outside the
tracked tree:

- Upstream tag: `v5.0.1`
- Upstream commit: `a60891aea193d92e7e5c3942700eca63f9d19a5f`
- Source archive:
  `https://github.com/Genymobile/scrcpy/archive/a60891aea193d92e7e5c3942700eca63f9d19a5f.tar.gz`
- Source archive SHA-256:
  `a0d699fc7388b8252416c49e6293639de39ab76a03e7302ddced56c284d45200`
- Official server:
  `https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1`
- Official server SHA-256:
  `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`
- Manual compiler SHA-256:
  `1d3df77343f35c6b2a82bd782bb265ecaca8431d9e09cae0e79b93756738f748`

`scripts/build_without_gradle.sh` is an unmodified copy of the upstream manual
compiler. `ordered-touch.patch` applies with `patch --fuzz=0` to a fresh copy of
the upstream `server/src` tree. `SHA256SUMS` pins every patched input.

The server version remains `5.0.1` for protocol compatibility. The manifest
records the patch identity and patch digest.

## Protocol

- Client to device: `128` (`u8`) + `pointerSequence` (`u64`, big endian),
  exactly 9 bytes.
- Finger touch DOWN and UP injections use
  `INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH`. MOVE remains asynchronous.
- Device to client after a request: `3` (`u8`) + sequence (`u64`, big endian)
  + `displayId` (`s32`, big endian) + success (`u8`, 0 or 1), exactly 14 bytes.
- `success=1` only when the UP was injected synchronously with a successful
  `WAIT_FOR_FINISH`, and the same pointer has a matching successful
  `WAIT_FOR_FINISH` DOWN on the same valid display. The ACK is queued only
  after both synchronous calls have returned; an async return is never treated
  as success.
- All pre-existing message types, layouts, and video paths remain unchanged.

An upstream v5.0.1 server rejects unknown control type 128, so this client
cannot silently fall back to an ordered-touch claim with the stock server.

## Build

Run from the repository root:

```sh
scripts/build-ordered-server.sh
```

The output is `.build/scrcpy-ordered/scrcpy-server`. The script creates a
clean source copy under `.build/scrcpy-ordered`, applies the patch without
fuzzing, runs focused protocol and touch-order tests, invokes the upstream
manual compiler, and verifies the resulting DEX.

The build uses the official Android SDK Platform 36 r02 archive and macOS
Build-Tools 36 macOS archive, checked against the Android repository SHA-1:

- `platform-36_r02.zip`: SHA-1
  `2c1a80dd4d9f7d0e6dd336ec603d9b5c55a6f576`, SHA-256
  `37607369a28c5b640b3a7998868d45898ebcb777565a0e85f9acf36f29631d2e`
- `build-tools_r36_macosx.zip`: SHA-1
  `199ae0047ee61e842f8ee0c6d3918e44fb9a1f83`, SHA-256
  `04e7f3a72044de4926fa038fa0e251a37bba1e1c3fb8beab6f8401bfd9eb4bf3`

The focused tests use these pinned Maven Central artifacts. They are reused
from `.build/scrcpy-ordered/deps` when the digest matches, or downloaded from
the fixed URL when absent:

- `https://repo1.maven.org/maven2/junit/junit/4.13.2/junit-4.13.2.jar`,
  SHA-256 `8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3`
- `https://repo1.maven.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar`,
  SHA-256 `66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9`

The pinned source files are recorded in `SHA256SUMS`. The patched source tree,
SDK cache, and binary are build artifacts and are excluded from version
control. The current reproducible output digest is
`0f69641a17d9e6aa2f5ea065523a08d1ce5d6a6ced873fc99399dd5b72869519`.

Licensed under Apache License 2.0. See `LICENSE`.
