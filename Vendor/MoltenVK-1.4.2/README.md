# MoltenVK 1.4.2

Macdora builds the fixed, unmodified upstream MoltenVK and SPIRV-Cross revisions described in [manifest.json](manifest.json). The public build uses public Metal APIs, does not apply downstream topology patches, and defaults to the Android Emulator host GL translator.

Run `bash scripts/build-moltenvk.sh` from the repository root. Source archives, build products, and receipts stay in `.build/moltenvk-upstream/`. Upstream licenses are preserved in `licenses/` and in the app bundle. The build verifies source checksums, arm64 architecture, linkage and the library signature.
