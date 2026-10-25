#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
  printf '%s\n' "$JAVA_HOME"
elif [[ -x /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/javac ]]; then
  printf '%s\n' /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
else
  /usr/libexec/java_home -v 21
fi
