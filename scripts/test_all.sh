#!/usr/bin/env bash
# Runs every test in the workspace: the app's `flutter test` at the root, then
# each library under packages/ that is a workspace member (`resolution:
# workspace` in its pubspec): `flutter test` for one that depends on the
# Flutter SDK, `dart test` for the rest. The root `flutter test` only runs
# the root test/ directory, so a package's own tests run nowhere else.
#
#   bash scripts/test_all.sh                 # everything
#   bash scripts/test_all.sh test/foo_test.dart   # args go to the app's run only
#   VPC_RESTRICTED_DIR=/nonexistent bash scripts/test_all.sh   # without the
#                                            # restricted fixtures, as a clone would
#
# Runs all of them even when one fails, then lists the failures and exits 1.
# See docs/libraries-migration.md.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

failed=()

echo "▶ app: flutter test $*"
flutter test "$@" || failed+=("app")

for pubspec in packages/*/pubspec.yaml; do
  grep -q '^resolution: workspace' "$pubspec" || continue
  dir=$(dirname "$pubspec")
  [ -d "$dir/test" ] || continue
  if grep -qE '^ +sdk: flutter' "$pubspec"; then runner=(flutter test); else runner=(dart test); fi
  echo "▶ $dir: ${runner[*]}"
  (cd "$dir" && "${runner[@]}") || failed+=("$dir")
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "✘ failed: ${failed[*]}"
  exit 1
fi
echo "✔ all passed"
