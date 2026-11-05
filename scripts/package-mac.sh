#!/bin/bash
# Builds an unsigned universal app and installer from public source candidates.
# The app uses ad-hoc signatures for macOS; no certificate or Keychain is used.
# Usage: scripts/package-mac.sh [--json]
set -euo pipefail
umask 022

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ -z "${STOREBENCH_TEST_MODE:-}" ] || fail 'Native packaging is forbidden in tests. Use inert fixtures through the guarded runner.'
[ "$(uname -s)" = Darwin ] || fail 'Build the native app on a Mac.'

json=0
for argument in "$@"; do
  case $argument in
    --json) [ $json = 0 ] || fail 'Use each option once.'; json=1 ;;
    --help) printf '%s\n' 'Usage: scripts/package-mac.sh [--json]'; exit 0 ;;
    *) fail 'Use --json for an artifact summary, or no options for an unsigned app and installer.' ;;
  esac
done

repo=$(cd "$(dirname "$0")/.." && pwd -P)
metadata_tool=(/usr/bin/swift "$repo/scripts/tools/package-info.swift")
# Unsigned builds carry placeholder metadata rather than release values.
version=0.0.0 build_number=1 bundle_id=app.storebench.desktop

build_root=$(mktemp -d "${TMPDIR:-/tmp}/storebench-native-release-XXXXXX")
build_root=$(cd "$build_root" && pwd -P)
output="$repo/dist-desktop" stage=source
finish() {
  local status=$?
  if [ $status != 0 ]; then
    mkdir -p -m 700 "$output"
    failure=$(mktemp -d "$output/failed-native-XXXXXX")
    [ -f "$build_root/build.log" ] && cp "$build_root/build.log" "$failure/build.log"
    printf 'SB-NATIVE-PACKAGE: The %s stage failed. Private diagnostics remain in ignored build output. No app was started, installed or uploaded.\n' "$stage" >&2
  fi
  rm -rf "$build_root"
  exit $status
}
trap finish EXIT
clean_env=(PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$build_root" TMPDIR="$build_root" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0)
step() {
  /usr/bin/env -i "${clean_env[@]}" "$@" >> "$build_root/build.log" 2>&1 || fail "Native package $(basename "$1") step failed."
}

stage=source
package="$build_root/package"
mkdir -m 700 "$package"
# Only public source candidates are built: Swift sources, JSON resources and the manifest.
while IFS= read -r -d '' file; do
  case $file in
    macos/Package.swift|macos/Package.resolved) ;;
    macos/Sources/*.swift|macos/Sources/*.json|macos/Tests/*.swift|macos/Tests/*.json) ;;
    *) continue ;;
  esac
  [ -f "$repo/$file" ] && [ ! -L "$repo/$file" ] || fail 'Native releases require regular public source candidates.'
  mkdir -p "$package/$(dirname "${file#macos/}")"
  cp "$repo/$file" "$package/${file#macos/}"
done < <(git -C "$repo" ls-files -z --cached --others --exclude-standard)
public() {
  git -C "$repo" ls-files --cached --others --exclude-standard -- "$1" | grep -qxF -- "$1" && [ -f "$repo/$1" ] && [ ! -L "$repo/$1" ] ||
    fail 'Native releases require regular public source candidates.'
  cp "$repo/$1" "$2"
}

stage=compile
build=(build -c release -Xswiftc -Osize --disable-keychain --disable-netrc --cache-path "$build_root/cache" --config-path "$build_root/configuration"
  --security-path "$build_root/security" --product Storebench --arch arm64 --arch x86_64)
(cd "$package" && step /usr/bin/swift "${build[@]}")
products=$(cd "$package" && /usr/bin/env -i "${clean_env[@]}" /usr/bin/swift "${build[@]}" --show-bin-path)

stage=runtime
app="$build_root/Storebench.app" contents="$build_root/Storebench.app/Contents"
resources="$contents/Resources" framework="$contents/Frameworks/SQLCipher.framework"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$resources"
cp "$products/Storebench" "$contents/MacOS/Storebench"
cp -R "$products/SQLCipher.framework" "$framework"
cp -R "$products/Storebench_StorebenchCore.bundle" "$resources/Storebench_StorebenchCore.bundle"
public LICENSE "$resources/LICENSE"

stage=framework
for name in Headers PrivateHeaders Modules; do
  entry="$framework/$name"
  [ -e "$entry" ] || continue
  target=$(cd "$entry" && pwd -P)
  case $target/ in "$framework"/*) ;; *) fail 'Framework metadata must remain inside the copied runtime.' ;; esac
  rm -rf "$target"; [ "$target" = "$entry" ] || rm -f "$entry"
done

stage=icon
public macos/Packaging/AppIcon.png "$build_root/AppIcon.png"
iconset="$build_root/AppIcon.iconset"; mkdir "$iconset"
for size in 16 32 128 256 512; do
  step /usr/bin/sips -z $size $size "$build_root/AppIcon.png" --out "$iconset/icon_${size}x${size}.png"
  step /usr/bin/sips -z $((size * 2)) $((size * 2)) "$build_root/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png"
done
step /usr/bin/iconutil -c icns -o "$resources/AppIcon.icns" "$iconset"
[ "$(head -c 4 "$resources/AppIcon.icns")" = icns ] || fail 'The compiled app icon is invalid.'
public macos/Packaging/PrivacyInfo.xcprivacy "$resources/PrivacyInfo.xcprivacy"

stage=metadata
public macos/Packaging/support-contact.json "$build_root/support-contact.json"
"${metadata_tool[@]}" "$bundle_id" "$version" "$build_number" "$build_root/support-contact.json" "$contents/Info.plist" AppIcon.icns
bytes() { find "$1" -type f -exec stat -f %z {} + | awk '{ sum += $1 } END { print sum + 0 }'; }
before=$(bytes "$app")

stage=optimize
before_runtime=$(/usr/bin/swift "$repo/scripts/tools/macho-runtime.swift" "$contents/MacOS/Storebench")
step /usr/bin/strip -S -x -N "$contents/MacOS/Storebench"
after_runtime=$(/usr/bin/swift "$repo/scripts/tools/macho-runtime.swift" "$contents/MacOS/Storebench")
[ "$(awk '{print $1, $2, $4}' <<< "$before_runtime")" = "$(awk '{print $1, $2, $4}' <<< "$after_runtime")" ] && awk '$3 != 0 {exit 1}' <<< "$after_runtime" ||
  fail 'Native executable symbol trimming must preserve its complete runtime.'
step /usr/bin/strip -S -x "$framework/SQLCipher"
step /usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$contents/MacOS/Storebench"

stage=architectures
[ "$(lipo -archs "$contents/MacOS/Storebench" | tr ' ' '\n' | sort | xargs)" = 'arm64 x86_64' ] &&
  [ "$(lipo -archs "$framework/SQLCipher" | tr ' ' '\n' | sort | xargs)" = 'arm64 x86_64' ] ||
  fail 'The complete native package must contain both Mac architectures.'

stage=signature
# Directories and executables are readable and executable by everyone, other files readable; links stay inside.
normalize() {
  while IFS= read -r -d '' entry; do
    if [ -L "$entry" ]; then
      target=$(cd "$(dirname "$entry")" && cd "$(dirname "$(readlink "$entry")")" && pwd -P)
      case $target/ in "$app"/*) ;; *) fail 'Native runtime links must stay inside the copied app bundle.' ;; esac
    elif [ -d "$entry" ]; then chmod 755 "$entry"
    elif [ -f "$entry" ]; then if [ -x "$entry" ]; then chmod 755 "$entry"; else chmod 644 "$entry"; fi
    else fail 'The native bundle contains an unsupported special file.'; fi
  done < <(find "$app" -print0)
}
normalize
# Ad-hoc signatures allow local execution without a signing identity.
step /usr/bin/xattr -cr "$app"
step /usr/bin/codesign --force --sign - "$framework"
step /usr/bin/codesign --force --sign - --identifier "$bundle_id" "$app"
step /usr/bin/codesign --verify --strict --deep "$app"
[ -z "$(/usr/bin/xattr -r "$app" 2>/dev/null | grep 'com.apple.quarantine' || true)" ] || fail 'The app still has a quarantine attribute.'

stage=size
after=$(bytes "$app") budget=$((100 * 1024 * 1024))
[ "$after" -le $budget ] && [ "$after" -lt "$before" ] || fail 'The complete native package must shrink and fit within its 100 MiB budget.'
name=Storebench-universal-unsigned

stage=installer
installer="$build_root/$name.pkg"
(cd "$build_root" && step /usr/bin/pkgbuild --component "$app" --install-location /Applications --identifier "$bundle_id" --version "$version" "$installer")

stage=output
mkdir -p -m 700 "$output"
release=$(mktemp -d "$output/$name-XXXXXX")
cp -R "$app" "$release/Storebench.app"
cp "$installer" "$release/"
summary=$(printf '{\n  "schemaVersion": 1,\n  "bundleId": "%s",\n  "version": "%s",\n  "buildNumber": "%s",\n  "architectures": ["arm64", "x86_64"],\n  "beforeBytes": %s,\n  "afterBytes": %s,\n  "budgetBytes": %s,\n  "distribution": "%s",\n  "signed": %s,\n  "uploaded": false,\n  "installed": false,\n  "started": false,\n  "notarized": false\n}' \
  "$bundle_id" "$version" "$build_number" "$before" "$after" "$budget" local false)
printf '%s\n' "$summary" > "$release/artifact.json"; chmod 600 "$release/artifact.json"
if [ $json = 1 ]; then printf '%s\n' "$summary"
else printf 'Unsigned universal app and installer: %s MiB including resources and ad-hoc signatures, in %s. Nothing was installed or started.\n' \
  "$(awk -v b="$after" 'BEGIN { printf "%.2f", b / 1048576 }')" "${release#"$repo/"}"
fi
