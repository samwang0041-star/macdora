# Third party notices

Macdora's original host application and original helper code are provided under the root MIT license. Third party code, source derivatives, libraries, and downloaded Android components retain their own licenses. The root license does not replace those licenses.

## Components distributed with the application

| Component | Fixed source | License and local notice |
| --- | --- | --- |
| scrcpy server and protocol | [Genymobile/scrcpy v5.0.1](https://github.com/Genymobile/scrcpy/tree/v5.0.1) | [Apache-2.0](Vendor/scrcpy-5.0.1/LICENSE), copyright Genymobile and Romain Vimont. |
| MoltenVK | [KhronosGroup/MoltenVK v1.4.2](https://github.com/KhronosGroup/MoltenVK/tree/v1.4.2) | [Apache-2.0](Vendor/MoltenVK-1.4.2/licenses/MoltenVK-LICENSE). |
| SPIRV-Cross | [KhronosGroup/SPIRV-Cross, 6c09849](https://github.com/KhronosGroup/SPIRV-Cross/tree/6c09849fe88c48eaed08413aa022aaa136a3a057) | [Apache-2.0](Vendor/MoltenVK-1.4.2/licenses/SPIRV-Cross-LICENSE). |
| Vulkan-Headers | [KhronosGroup/Vulkan-Headers, e3b1eec](https://github.com/KhronosGroup/Vulkan-Headers/tree/e3b1eec08173d6b825cd3ac88c885a63b621504a) | [Apache-2.0 or MIT, per file](Vendor/MoltenVK-1.4.2/licenses/Vulkan-Headers-LICENSE.md). |
| cereal | [USCiLab/cereal, a56bad8](https://github.com/USCiLab/cereal/tree/a56bad8bbb770ee266e930c95d37fff2a5be7fea) | [BSD-3-Clause](Vendor/MoltenVK-1.4.2/licenses/cereal-LICENSE). |

The scrcpy build applies Macdora's ordered input acknowledgments, related touch handling changes, and an in-place display/encoder reconfiguration protocol with bounded output polling for reset and shutdown. The replacement Android input controller is in `Guest/OrderedScrcpy`; its use with the upstream server remains under Apache-2.0. The server's upstream license and a modification notice are included in the app's `Contents/Resources/Notices` directory.

The public preview builds MoltenVK and SPIRV-Cross from the unmodified upstream sources described in [the fixed build manifest](Vendor/MoltenVK-1.4.2/manifest.json). It uses public Metal APIs and defaults to Android Emulator's host GL translator. This release does not include downstream dynamic topology or signed zero patches. Experimental Guest ANGLE selection is a development option and is not a promise of GLES feature parity.

CPM.cmake 0.40.8 is a build tool under the [MIT license](https://github.com/cpm-cmake/CPM.cmake/blob/v0.40.8/LICENSE). It is cached during builds and is not an application runtime dependency.

## Android environment downloaded on demand

Android Emulator, platform-tools, and the AOSP arm64 system image are obtained from Google's fixed official archives after the user chooses to download the environment. These components are not embedded in the normal Macdora installer. Their license, source, and notice files remain in their downloaded directories; Google SDK components are subject to their applicable SDK terms. See [Android SDK terms](https://developer.android.com/studio/terms) and the [Android source licenses](https://source.android.com/docs/setup/about/licenses).

The official graphics stack also uses [ANGLE](https://chromium.googlesource.com/angle/angle/) and other dependencies covered by the notices in the emulator distribution. An [ANGLE BSD license copy](Vendor/MoltenVK-1.4.2/licenses/ANGLE-LICENSE) is retained for reference. It does not relicense code by other authors.

In tablet mode, Macdora overlays an ActivityEmbedding split-attributes and draggable-divider compatibility patch (`Guest/WindowExtensionsPatch`, derived from AOSP `androidx.window.extensions` under Apache-2.0, copyright The Android Open Source Project) onto the guest's `androidx.window.extensions.jar` at runtime so legacy ActivityEmbedding applications support desktop split-pane resizing and multi-pane focus semantics.

Macdora does not include third party business applications. Users select their own APK files, which remain subject to the corresponding application owners' terms.

## Product references

Exploration of Android applications on macOS was informed by products such as [AndroMeld](https://andromeld.catchingnow.com/) and existing desktop management interfaces. A product reference does not imply affiliation or permission to redistribute that product's proprietary code or assets. The public preview uses independently implemented native AppKit interfaces and the upstream components listed above.

Macdora's wordmark and app icon are included as product brand assets. Native SF Symbols are supplied by macOS and remain subject to Apple's applicable terms.
