#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRANDOMX_DIR="${ROOT_DIR}/Sources/CRandomX"

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

echo "==> Copying RandomX src/ files..."
cp -r "${TMP_DIR}/RandomX/src"/* "${CRANDOMX_DIR}/"
cp "${TMP_DIR}/RandomX/LICENSE" "${CRANDOMX_DIR}/"

echo "==> RandomX source populated successfully."
