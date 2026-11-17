#!/usr/bin/env bash
# Builds the lab's profile APK and installs it over the app, keeping its
# data (`adb install -r`, never an uninstall).
#
#   tool/lab/build.sh [dart-defines...]
#
# Fails on a build or install error instead of leaving an older build on the
# phone. Extra arguments go to `flutter build apk`.
source "$(dirname "$0")/lab.sh"

log="$EXAMPLE_DIR/perf/lab/build.log"
mkdir -p "$(dirname "$log")"
echo "building (log: $log)"
if ! (cd "$EXAMPLE_DIR" && flutter build apk --profile --target-platform android-arm64 \
  --dart-define=MPX_LAB=true "$@" >"$log" 2>&1); then
  grep -E "^e: |Error|FAILURE|error:" "$log" | head -10 >&2
  die "build failed"
fi
apk="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-profile.apk"
D install -r "$apk" >/dev/null ||
  die "install failed (signed by another key? this script never uninstalls)"
echo "installed $(wc -c <"$apk" | tr -d ' ')B on $DEVICE"
