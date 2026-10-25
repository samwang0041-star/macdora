# Location plugin

`builtin.developer.location` version `1.0.1` uses the existing hardware GNSS
driver and lifecycle hooks. Its initial point is an explicitly labeled sample
location at Shanghai People's Square (`31.230416, 121.473701`, GCJ-02).
The background location whitelist contains the GNSS helper and applications
discovered in the guest, with no application-specific presets.

## Build and sign

Use the Android SDK inputs and JDK described in `docs/DEVELOPMENT.md`. The scripts
accept `ANDROID_USE_BUILD_TOOLS`, `ANDROID_USE_ANDROID_JAR`, and `ANDROID_USE_JDK`.
macOS Swift and CryptoKit verify Ed25519 signatures; OpenSSL 3 generates
deterministic Ed25519 signatures. Select its executable with `MACDORA_OPENSSL`
if it is not the `openssl` on your PATH. Python uses only its standard library.
No GitHub token is needed for a local build.

Select both signing files explicitly. For a developer build, for example:

```sh
python3 scripts/build-location-plugin.py \
  --private-key .build/plugin-signing/developer.key \
  --key-id developer-local \
  --publisher developer-local \
  --generate-key \
  --helper-keystore .build/plugin-signing/developer-helper.keystore \
  --create-helper-keystore
```

These switches create missing keys and reuse existing ones. The Ed25519 key is
32 raw bytes, stored with mode `0600`. The helper uses a separate RSA APK
keystore, also stored with mode `0600`. Its local keystore password comes from
`MACDORA_GNSS_KEYSTORE_PASSWORD` (default `android`). Keep both files outside
public sources or in ignored `.build/`. Back up maintainer keys securely.
The scripts never edit the host's trusted keys. A developer signature does not
inherit the host's official trust; `builtin.*` still requires an explicitly
trusted Ed25519 key. Do not upload a locally resigned registry as an official
release.

Maintainer builds use `--key-id official-ed25519-v2`,
`--publisher samwang0041-star`, and explicitly select the maintainer's key at
`.build/plugin-signing/official-ed25519-v2.key` plus its helper keystore.
`--generate-key` is for initial setup and does not rotate an existing key.

The helper is always compiled from `Guest/GNSSKeepWarm/`; an old APK is never
an input. Its Java service subscribes to GPS updates, stops listening on STOP
and destruction, and contains no network or application-specific behavior.
Its package, minimum API 29, target API 34, and exported service contract are
preserved; the helper version is `1.0.1` / code `2`.

Generated outputs are:

- `builtin.developer.location.auplugin/`: installable source package, generated
  shell hooks containing the freshly compiled APK, and `signature.json`.
- `dist/builtin.developer.location.auplugin`: deterministic signed ZIP.
- `dist/build-info.json`: public source and output hashes.
- `registry.json`: source and Release URLs for `samwang0041-star/macdora`.

Edit hook templates in `templates/`, then rebuild. The signer hashes every
regular file except `signature.json`, uses the host's canonical payload format,
and verifies the resulting Ed25519 signature with CryptoKit. Key bytes are
passed to OpenSSL through a pipe and are never written to another key file.
APK and ZIP entries use fixed
timestamps and sorted names. Rebuilding with the same source, SDK/JDK, Python
ZIP implementation, and both signing keys produces the same hashes. New APK
certificates change APK bytes; a new developer's keys are not expected to
reproduce the maintainer's signature.

## Lifecycle and checks

Enable and runtime-ready hooks save the original guest location settings,
grants, and app-op modes before changing them. The app-launch hook handles a
newly installed active application using its real package. Disable stops and
uninstalls only the stateless GNSS helper, restores saved settings and grants,
and removes the guest's temporary plugin state. On a helper certificate
conflict, enable replaces only that helper; other installation failures report
`AU_PLUGIN_HOOK_FAIL`.

```sh
python3 plugins/tests/test_location_hooks.py
swift scripts/build-location-plugin.swift verify \
  plugins/builtin.developer.location.auplugin --public-key YOUR_PUBLIC_KEY_BASE64
```

The shell tests use mocked Android commands and temporary directories. They do
not access a user's runtime. Verify a release archive against `archiveSHA256`,
then verify its extracted package against an independently trusted public key.
The public key embedded in a downloaded registry does not establish trust.

Building and signing write local outputs only. Publishing requires a separate
explicit authorization through the project's release process.
