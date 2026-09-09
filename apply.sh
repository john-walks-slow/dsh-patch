#!/usr/bin/env bash
# Apply all dsh deployment patches to the installed @deepseek-ai/dsh tree.
# Idempotent: already-applied patches are skipped; context-mismatch (e.g. after
# a dsh upgrade changed the surrounding code) fails loudly instead of silently.
set -euo pipefail

# Resolve the dsh install root from the `dsh` binary, fall back to the global path.
if command -v dsh >/dev/null 2>&1; then
	DROOT="$(dirname "$(dirname "$(readlink -f "$(command -v dsh)")")")"
else
	DROOT="/usr/lib/node_modules/@deepseek-ai/dsh"
fi
if [ ! -d "$DROOT/node_modules/@deepseek-ai/dsh-host-apiproxy" ]; then
	echo "✗ dsh install root not found at $DROOT" >&2
	exit 1
fi
echo "DSH install root: $DROOT"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
cd "$DROOT"

for p in "$DIR"/*.patch; do
	[ -e "$p" ] || continue
	name="$(basename "$p")"
	if patch -p1 --dry-run <"$p" >/dev/null 2>&1; then
		patch -p1 <"$p" >/dev/null && echo "  ✓ applied: $name"
	elif patch -p1 -R --dry-run <"$p" >/dev/null 2>&1; then
		echo "  ⊘ already applied, skipping: $name"
	else
		echo "  ✗ FAILED (context mismatch — dsh version likely changed, re-derive the patch): $name" >&2
		exit 1
	fi
done

echo
echo "Done. Restart dsh to load patched code:"
echo "  supervisorctl restart dsh"
