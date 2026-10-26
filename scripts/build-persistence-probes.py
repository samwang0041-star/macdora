#!/usr/bin/env python3
"""Build two offline apps with separate Android UIDs for data-retention acceptance."""

import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile


def run(*command):
    subprocess.run([str(part) for part in command], check=True)


def main():
    root = Path(__file__).resolve().parents[1]
    run("bash", root / "scripts/build-android-probe.sh")
    tools = Path(os.environ.get("ANDROID_PROBE_BUILD_TOOLS", root / ".cache/android-sdk/build-tools/android-16"))
    android_jar = Path(os.environ.get("ANDROID_PROBE_ANDROID_JAR", root / ".cache/android-sdk/platforms/android-36/android.jar"))
    jdk = os.environ.get("ANDROID_PROBE_JDK_HOME") or subprocess.check_output(
        ["bash", str(root / "scripts/java-home.sh")], text=True
    ).strip()
    signer = [str(Path(jdk) / "bin/java"), "-jar", str(tools / "lib/apksigner.jar")]
    source = root / "Tests/AndroidProbe"
    namespace = "{http://schemas.android.com/apk/res/android}"
    ET.register_namespace("android", "http://schemas.android.com/apk/res/android")
    with zipfile.ZipFile(root / ".build/android-probe/android-use-probe.apk") as apk:
        dex = apk.read("classes.dex")

    for variant in ["a", "b"]:
        output = root / ".build/android-persistence-probes" / variant
        output.mkdir(parents=True, exist_ok=True)
        manifest = ET.parse(source / "AndroidManifest.xml")
        package = "com.example.macdora.retention" + variant
        manifest.getroot().set("package", package)
        application = manifest.getroot().find("application")
        application.set(namespace + "label", "数据保留测试 " + variant.upper())
        launcher = application.find("activity[@" + namespace + "name='.MainActivity']")
        persistence = application.find("activity[@" + namespace + "name='.PersistenceActivity']")
        for intent_filter in list(launcher.findall("intent-filter")):
            launcher.remove(intent_filter)
            persistence.append(intent_filter)
        persistence.set(namespace + "exported", "true")
        for activity in application.findall("activity"):
            name = activity.get(namespace + "name")
            if name.startswith("."):
                activity.set(namespace + "name", "local.androiduse.probe" + name)
        manifest.write(output / "AndroidManifest.xml", encoding="utf-8", xml_declaration=True)
        unsigned = output / "unsigned.apk"
        run(tools / "aapt", "package", "-f", "-M", output / "AndroidManifest.xml",
            "-S", source / "res", "-I", android_jar, "-F", unsigned)
        # Resource definitions stay identical, so compiled R IDs and classes.dex
        # are shared. Application IDs differ, giving each fixture its own data/keys.
        with zipfile.ZipFile(unsigned, "a", compression=zipfile.ZIP_DEFLATED) as apk:
            apk.writestr("classes.dex", dex)
        aligned = output / "aligned.apk"
        final = output / ("retention-" + variant + ".apk")
        run(tools / "zipalign", "-f", "-p", "4", unsigned, aligned)
        run(*signer, "sign", "--ks", root / ".build/android-probe-signing/debug.keystore",
            "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android",
            "--key-pass", "pass:android", "--out", final, aligned)
        run(*signer, "verify", final)
        print(package + ": " + str(final))


if __name__ == "__main__":
    main()
