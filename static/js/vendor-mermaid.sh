#!/bin/bash
# Fetch mermaid.min.js from the official npm registry.
# Usage: bash static/js/update-mermaid.sh [VERSION]
# If no version given, fetches the latest.
# Use `datalad run` to record provenance.

set -eu

VERSION="${1:-latest}"
OUTDIR="$(dirname "$0")"

URL="https://cdn.jsdelivr.net/npm/mermaid@${VERSION}/dist/mermaid.min.js"

echo "Fetching mermaid@${VERSION} from ${URL}..."
curl -sL -o "${OUTDIR}/mermaid.min.js" "${URL}"
echo "Saved to ${OUTDIR}/mermaid.min.js ($(wc -c < "${OUTDIR}/mermaid.min.js") bytes)"
