#!/usr/bin/env bash
# Checks out microsoft/typescript-go at the pinned commit (with the TypeScript
# submodule, which holds the conformance test cases) into vendor/typescript-go.
set -euo pipefail
cd "$(dirname "$0")/.."
commit="$(cat UPSTREAM_COMMIT)"
dir=vendor/typescript-go
if [ ! -d "$dir/.git" ]; then
    mkdir -p vendor
    git init -q "$dir"
    git -C "$dir" remote add origin https://github.com/microsoft/typescript-go
fi
git -C "$dir" fetch -q --depth 1 origin "$commit"
git -C "$dir" checkout -q "$commit"
git -C "$dir" submodule update --init --depth 1
echo "vendor/typescript-go at $(git -C "$dir" rev-parse HEAD)"
