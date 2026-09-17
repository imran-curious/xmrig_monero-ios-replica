#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRANDOMX_DIR="${ROOT_DIR}/Sources/CRandomX"

# Files under Sources/CRandomX/ that belong to this project, not to upstream
# RandomX. jit_compiler_a64.{cpp,hpp} exist upstream too, but ours are patched
# to keep separate writable (code) and executable (codeExec) views of the same
# pages - that is what makes the iOS 26 debugger arena work. Copying upstream
# over them silently drops the JIT and the miner falls back to 400 H/s.
PROJECT_OWNED=(
    jit26_arena.c
    jit26_arena.h
    rx_shim.c
    jit_compiler_a64.cpp
    jit_compiler_a64.hpp
)

echo "==> Setting up CRandomX in ${CRANDOMX_DIR}..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [ -d "/tmp/RandomX-src" ]; then
    echo "==> Using cached /tmp/RandomX-src..."
    cp -r /tmp/RandomX-src "${TMP_DIR}/RandomX"
else
    echo "==> Cloning tevador/RandomX (master)..."
    git clone --depth 1 https://github.com/tevador/RandomX.git "${TMP_DIR}/RandomX"
fi

mkdir -p "${CRANDOMX_DIR}/include"

# Stage upstream first, then drop anything this project owns, so the copy below
# can never overwrite a patched file.
STAGE_DIR="${TMP_DIR}/stage"
mkdir -p "${STAGE_DIR}"
cp -r "${TMP_DIR}/RandomX/src"/* "${STAGE_DIR}/"

for f in "${PROJECT_OWNED[@]}"; do
    if [ -e "${CRANDOMX_DIR}/${f}" ]; then
        rm -f "${STAGE_DIR}/${f}"
        echo "==> Keeping local ${f}"
    fi
done

echo "==> Copying RandomX src/ files..."
cp -r "${STAGE_DIR}"/* "${CRANDOMX_DIR}/"
cp "${TMP_DIR}/RandomX/LICENSE" "${CRANDOMX_DIR}/"

echo "==> RandomX source populated successfully."
