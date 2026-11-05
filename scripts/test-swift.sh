#!/bin/bash
# Guarded native checks: compiles the Swift package and runs its synthetic tests inside a fresh owned root.
# The app is never launched. Native networking is denied, private home data is unreadable and writes stay in the run.
# Usage: scripts/test-swift.sh [unit]
set -euo pipefail
umask 077

fail() { printf '%s\n' "$*" >&2; exit 1; }
suite=${1:-unit}; [ $# -gt 0 ] && shift
[ "$suite" = unit ] && [ $# = 0 ] || fail "Run the unit suite: scripts/test-swift.sh unit"
tests=1
[ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sandbox-exec ] || fail "Guarded Swift checks require macOS and its process sandbox."
[ -z "${STOREBENCH_TEST_MODE:-}" ] || fail "Start guarded Swift checks from a normal shell, not from inside another test run."

repo=$(cd "$(dirname "$0")/.." && pwd -P)
macos="$repo/macos" cache="$repo/macos/.build"

# The pinned SQLCipher package must already be resolved; guarded runs never touch the network.
[ -d "$cache/checkouts/SQLCipher.swift" ] || fail "Resolve the pinned Swift dependency first: swift package resolve --package-path macos --disable-keychain --disable-netrc"
state="$cache/workspace-state.json" resolved="$macos/Package.resolved"
value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
[ "$(value "$state" object.artifacts)" = 1 ] && [ "$(value "$state" object.dependencies)" = 1 ] &&
  [ "$(value "$state" object.artifacts.0.packageRef.identity)" = sqlcipher.swift ] &&
  [ "$(value "$resolved" pins)" = 1 ] && [ "$(value "$resolved" pins.0.identity)" = sqlcipher.swift ] &&
  [ "$(value "$resolved" pins.0.state.revision)" = "$(value "$state" object.dependencies.0.state.checkoutState.revision)" ] &&
  [ "$(value "$state" object.dependencies.0.state.checkoutState.version)" = 4.19.0 ] &&
  [ "$(value "$state" object.artifacts.0.source.checksum)" = 39f02d2f04f0de2ba1facf215550bfc6e6e2c9971d5d8ebb0cdd604874781bd7 ] ||
  fail "The cached native dependency does not match the pinned package."
cached_artifact="$cache/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework"
cache_real=$(cd "$cache" && pwd -P)
artifact_real=$(cd "$cached_artifact" && pwd -P)
declared_real=$(cd "$(value "$state" object.artifacts.0.path)" && pwd -P)
checkout_real=$(cd "$cache/checkouts/SQLCipher.swift" && pwd -P)
[ "$artifact_real" = "$declared_real" ] && case $artifact_real/ in "$cache_real"/*) true ;; *) false ;; esac &&
  case $checkout_real/ in "$cache_real"/*) true ;; *) false ;; esac || fail "Native cached dependencies must stay inside the package cache."

# A fresh owned root with the marker the Swift TestIsolation contract checks on every access.
root=$(mktemp -d "${TMPDIR:-/tmp}/storebench-isolated-test-XXXXXX")
root=$(cd "$root" && pwd -P)
children=()
cleanup() {
  for child in "${children[@]:-}"; do [ -n "$child" ] && kill "$child" 2>/dev/null || true; done
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
token=$(/usr/bin/uuidgen)
printf %s "$token" > "$root/.test-run"
mkdir -m 700 "$root/data" "$root/native-fixtures" "$root/swift-home" "$root/swift-package"
/usr/bin/tar -xzf "$macos/Tests/Fixtures/native-fixtures.tar.gz" -C "$root/native-fixtures"

# Copy only Swift sources, JSON resources and the manifest into the owned package.
source="$root/swift-package" build="$root/swift-package/.build"
cp "$macos/Package.swift" "$macos/Package.resolved" "$source/"
for folder in Sources Tests; do
  if [ -n "$(find "$macos/$folder" -type l -print -quit)" ]; then fail "Native test source must not contain symbolic links."; fi
  (cd "$macos" && find "$folder" -type f \( -name '*.swift' -o -name '*.json' \) -print0 | /usr/bin/cpio -0pdm "$source" 2>/dev/null)
done
mkdir -p "$build/checkouts" "$build/artifacts/sqlcipher.swift/SQLCipher"
cp -RL "$cache/checkouts/SQLCipher.swift" "$build/checkouts/SQLCipher.swift"
artifact_target="$build/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework"
cp -RL "$cached_artifact" "$artifact_target"
cp "$state" "$build/workspace-state.json"
/usr/bin/plutil -replace object.artifacts.0.path -string "$artifact_target" "$build/workspace-state.json"

# Seatbelt profiles: no network, no private home reads, writes only inside this run.
home=$(cd ~ && pwd -P)
quote() { local text=${1//\\/\\\\}; printf '"%s"' "${text//\"/\\\"}"; }
ancestors=""
parent=$(dirname "$source")
while [ "$parent" != / ]; do ancestors="$ancestors (require-not (literal $(quote "$parent")))"; parent=$(dirname "$parent"); done
private_files="(require-all (subpath $(quote "$home")) (require-not (subpath $(quote "$root")))$ancestors)"
protections="(version 1) (allow default) (deny network*) (deny file-read* $private_files)"
sandbox="$protections (deny file-write* (require-not (subpath $(quote "$root"))))"
# The compiler also uses macOS's atomic-file replacement folders; it may write system compiler
# caches but cannot read private home data or reach the network.
compiler_sandbox="$protections (deny file-write* $private_files)"

native_env=(PATH=/usr/bin:/bin:/usr/sbin:/sbin USER="$(id -un)" LOGNAME="$(id -un)" TMPDIR="$root" TMP="$root" TEMP="$root"
  HOME="$root/swift-home" CFFIXED_USER_HOME="$root/swift-home" CLANG_MODULE_CACHE_PATH="$root/clang-cache"
  SWIFTPM_MODULECACHE_OVERRIDE="$root/swift-cache" xcrun_nocache=1
  STOREBENCH_TEST_MODE=1 STOREBENCH_TEST_ROOT="$root" STOREBENCH_TEST_TOKEN="$token")
in_env() { (cd "$source" && /usr/bin/env -i "${native_env[@]}" "$@"); }
scrub() { sed -e "s#$source#macos#g" -e "s#$root#<isolated-run>#g" -e "s#$home#<user-home>#g"; }
log="$root/native.log"
# Loader variables are set after sandbox-exec starts; protected launchers strip inherited DYLD variables.
run() {
  local profile=$1; shift
  if ! in_env /usr/bin/sandbox-exec -p "$profile" "$@" > "$log" 2>&1; then
    printf 'Guarded Swift command failed.\n' >&2
    grep -E -A3 'recorded an issue|Expectation failed:|error:|threw error|fatal error:|✘ Test .*failed' "$log" | head -200 | scrub >&2 || true
    tail -c 12000 "$log" | scrub >&2
    exit 1
  fi
}

compiler=$(in_env /usr/bin/xcrun --find swift)
stripper=$(in_env /usr/bin/xcrun --find strip)
testing_helper=$(cd "$(dirname "$compiler")/../libexec/swift/pm" && pwd -P)/swiftpm-testing-helper
platform=$(in_env /usr/bin/xcrun --sdk macosx --show-sdk-platform-path)
# SwiftPM's manifest sandbox cannot nest inside Seatbelt; the outer sandbox covers manifest, compiler and tests.
common=(--package-path "$source" -c release -Xswiftc -Osize --build-system native --disable-keychain --disable-netrc
  --disable-automatic-resolution --skip-update --disable-sandbox)

echo "Compiling Swift app and core fixtures offline; native networking and credential access are blocked."
run "$sandbox" /usr/bin/touch "$build/sandbox-probe"
run "$sandbox" /bin/cat "$build/sandbox-probe"
if [ $tests = 1 ]; then run "$compiler_sandbox" "$compiler" build --build-tests -Xswiftc -enable-testing "${common[@]}"
else run "$compiler_sandbox" "$compiler" build "${common[@]}"; fi

# Strip an executable copy and prove its runtime is unchanged; optionally re-sign it for execution.
trim() {
  local file=$1 before after
  before=$(/usr/bin/swift "$repo/scripts/tools/macho-runtime.swift" "$file")
  run "$compiler_sandbox" "$stripper" -S -x -N "$file"
  after=$(/usr/bin/swift "$repo/scripts/tools/macho-runtime.swift" "$file")
  [ "$(awk '{print $1, $2, $4}' <<< "$before")" = "$(awk '{print $1, $2, $4}' <<< "$after")" ] && awk '$3 != 0 {exit 1}' <<< "$after" ||
    fail "Native executable symbol trimming must preserve its complete runtime."
  if [ "${2:-}" = sign ]; then
    run "$compiler_sandbox" /usr/bin/codesign --force --sign - "$file"
    [ "$(/usr/bin/swift "$repo/scripts/tools/macho-runtime.swift" "$file")" = "$after" ] || fail "Native executable signing must preserve its runtime."
  fi
}
# SHA-256 prefix of the arguments joined with NUL bytes, as the Swift lock names are derived.
sha() {
  local length=$1; shift
  { local first=1 part; for part in "$@"; do [ $first = 1 ] || printf '\0'; printf '%s' "$part"; first=0; done; } | /usr/bin/shasum -a 256 | cut -c1-"$length"
}

if [ $tests = 1 ]; then
  fixture_binary="$build/release/StorebenchPolicyFixtures"
  trim "$fixture_binary" sign
  # Owned helpers hold the same process-shared mutexes the Swift tests must wait for.
  account=$(sha 32 'synthetic-account' '1000000001') import=$(sha 48 'synthetic-account' '1000000001')
  policies=(
    "display-preferences-save-policy|state-v2/display_preferences.mutex|"
    "session-backup-close-policy|state-v2/backup_media.mutex|"
    "history-lock-policy|state-v2/import_$import.lock.mutex|"
    "reporter-lock-policy|state-v2/reporter_$(sha 32 'synthetic-account').mutex|"
    "storage-lock-policy|state-v2/bootstrap.mutex|"
    "review-draft-lock-policy|state-v2/review_info_$(sha 40 'synthetic-account:1000000001:version-1').mutex|"
    "review-layout-lock-policy|state-v2/review_info_view_$(sha 40 'synthetic-account:1000000001:view').mutex|"
    "vault-lock-policy|credential-state/vault.mutex|"
    "sales-lock-policy|state-v2/sales-$account.mutex|"
    "sales-sync-scope-lock-policy|state-v2/sales-$account.mutex|"
    "sales-sync-cancel-lock-policy|state-v2/sales-$account.mutex|"
    "financial-lock-policy|state-v2/financial-$account.mutex|"
    "analytics-lock-policy|state-v2/analytics-$account.mutex|"
    "analytics-job-lock-policy|state-v2/report_$(sha 48 'analytics' 'synthetic-account' '1000000001').lock.mutex|"
    "analytics-job-cancel-save-lock-policy|state-v2/analytics-$account.mutex|"
    "import-job-recovery-policy|state-v2/import_$import.lock.mutex|00000000-0000-4000-8000-000000000071"
    "import-job-interrupted-policy|state-v2/import_$import.lock.mutex|00000000-0000-4000-8000-000000000072"
    "financial-review-lock-policy|state-v2/financial_reviews_$account.mutex|"
    "financial-job-retained-policy|state-v2/report_$(sha 48 'financial' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000091"
    "financial-job-interrupted-policy|state-v2/report_$(sha 48 'financial' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000092"
    "sales-job-complete-policy|state-v2/report_$(sha 48 'sales' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000101"
    "sales-job-interrupted-policy|state-v2/report_$(sha 48 'sales' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000102"
    "reviews-job-complete-policy|state-v2/report_$(sha 48 'reviews' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000111"
    "reviews-job-interrupted-policy|state-v2/report_$(sha 48 'reviews' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000112"
    "reviews-save-cancel-policy|state-v2/reviews-$account.mutex|"
    "reviews-save-scope-policy|state-v2/reviews-$account.mutex|"
    "reviews-file-cancel-policy|state-v2/reviews-$account.mutex|"
    "reviews-file-scope-policy|state-v2/reviews-$account.mutex|"
    "sync-job-complete-policy|state-v2/report_$(sha 48 'sync' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000121"
    "sync-job-interrupted-policy|state-v2/report_$(sha 48 'sync' 'synthetic-account' '1000000001').lock.mutex|00000000-0000-4000-8000-000000000122"
    "sync-receipt-cancel-policy|state-v2/sync_receipts_$account.mutex|"
    "sync-receipt-scope-policy|state-v2/sync_receipts_$account.mutex|"
  )
  themes=$(sha 40 '"synthetic-account:1000000001"')
  for action in prepare save; do for check in cancel scope; do policies+=("review-theme-$action-$check-policy|state-v2/review_themes_$themes.mutex|"); done; done
  for policy in "${policies[@]}"; do
    IFS='|' read -r name mutex job <<< "$policy"
    mkdir -m 700 "$root/$name"
    owner=(); [ -n "$job" ] && owner=(--job-owner "$job")
    (cd "$source" && exec /usr/bin/env -i "${native_env[@]}" /usr/bin/sandbox-exec -p "$sandbox" "$fixture_binary" \
      "$root/$name/$mutex" "$root/$name/lock-ready" "$root/$name/lock-release" ${owner[@]+"${owner[@]}"} > "$root/$name.log" 2>&1) &
    children+=($!)
  done
  deadline=$((SECONDS + 10))
  for policy in "${policies[@]}"; do
    name=${policy%%|*}
    until [ -e "$root/$name/lock-ready" ]; do
      for child in "${children[@]}"; do kill -0 "$child" 2>/dev/null || { wait "$child" || fail "A guarded native lock fixture failed before it was ready."; }; done
      [ $SECONDS -lt $deadline ] || fail "The guarded native lock fixture did not become ready ($name)."
      sleep 0.01
    done
  done
  # Execute the compiled test bundle directly; SwiftPM test would replan the build.
  bundle="$build/release/StorebenchPackageTests.xctest/Contents/MacOS/StorebenchPackageTests"
  run "$sandbox" /usr/bin/env DYLD_FRAMEWORK_PATH="$platform/Developer/Library/Frameworks" "$testing_helper" --test-bundle-path "$bundle" --testing-library swift-testing
  output=$(scrub < "$log")
  for child in "${children[@]}"; do wait "$child" || fail "A guarded native lock fixture failed."; done
  children=()
  grep -Eq 'Test run with [1-9][0-9]* tests( in [0-9]+ suites)? passed' <<< "$output" && ! grep -qw skipped <<< "$output" ||
    { printf 'The guarded Swift suite must run and pass every test.\n%s\n' "$output" | tail -c 20000 >&2; exit 1; }
  printf '%s\n' "$output"
  exit 0
fi
