#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:?output directory required}"
mkdir -p "$OUT_DIR"

tar   --sort=name   --mtime='@0'   --owner=0   --group=0   --numeric-owner   --format=ustar   -cf "$OUT_DIR/sanogo-provenance-artifact.tar"   artifact.txt
