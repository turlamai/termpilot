#!/bin/sh
# Release version consistency: package.json == backend app-version ==
# CHANGELOG head section. Run in CI before packaging and locally before
# tagging. An annotated tag v<version> is the only release trigger.
set -eu

cd "$(dirname "$0")/.."

TAG="${1:-}"
ROOT_VERSION=$(node -p "require('./package.json').version")
BACKEND_VERSION=$(sed -n 's/.*(define app-version "\([^"]*\)").*/\1/p' backend/main.rkt)

echo "package.json=$ROOT_VERSION backend=$BACKEND_VERSION tag=${TAG:-none}"

[ -n "$BACKEND_VERSION" ] || { echo "backend/main.rkt has no app-version" >&2; exit 1; }
[ "$ROOT_VERSION" = "$BACKEND_VERSION" ] || { echo "package.json != backend app-version" >&2; exit 1; }

if [ -n "$TAG" ]; then
  [ "${TAG#v}" = "$ROOT_VERSION" ] || { echo "tag != package.json version" >&2; exit 1; }
fi

grep -q "^## \[$ROOT_VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no '## [$ROOT_VERSION]' section" >&2; exit 1; }

echo "version-consistency ok"
