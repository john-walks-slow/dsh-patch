#!/usr/bin/env bash
# Apply all dsh deployment patches to the installed @deepseek-ai/dsh tree.
# Idempotent: already-applied patches are skipped; context-mismatch (e.g. after
# a dsh upgrade changed the surrounding code) fails loudly instead of silently.
set -euo pipefail

# --check: report status only, never touch the install tree.
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# Resolve the dsh install root from the `dsh` binary, fall back to the global path.
if command -v dsh >/dev/null 2>&1; then
	DROOT="$(dirname "$(dirname "$(readlink -f "$(command -v dsh)")")")"
else
	DROOT="/usr/lib/node_modules/@deepseek-ai/dsh"
fi
if [ ! -d "$DROOT/node_modules/@deepseek-ai/dsh-subprocess-local" ]; then
	echo "✗ dsh install root not found at $DROOT" >&2
	exit 1
fi
echo "DSH install root: $DROOT"

# Some patches target a content-hashed rollup chunk (e.g.
# dsh-subprocess-local/lib/runner-launch-<hash>.js). A dsh upgrade that merely
# re-hashes that chunk keeps the code identical but makes the patch text stop
# matching, which is how 0001 went silently missing after the 2026-09-28 upgrade.
# Rewrite any chunk filename in the patch to whatever is installed right now, so
# only real context changes fail.
SUBPROCESS_LIB="$DROOT/node_modules/@deepseek-ai/dsh-subprocess-local/lib"
CHUNK_NAME=""
if [ -d "$SUBPROCESS_LIB" ]; then
	CHUNK_NAME="$(cd "$SUBPROCESS_LIB" && ls runner-launch-*.js 2>/dev/null | head -n 1 || true)"
fi
[ -n "$CHUNK_NAME" ] && echo "subprocess-local chunk: $CHUNK_NAME"

render_patch() {
	if [ -n "$CHUNK_NAME" ]; then
		sed -E "s#runner-launch-[A-Za-z0-9_-]+\.js#${CHUNK_NAME}#g" "$1"
	else
		cat "$1"
	fi
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
cd "$DROOT"

for p in "$DIR"/*.patch; do
	[ -e "$p" ] || continue
	name="$(basename "$p")"
	if render_patch "$p" | patch -p1 --dry-run >/dev/null 2>&1; then
		if [ "$CHECK_ONLY" = "1" ]; then
			echo "  ✗ MISSING (would apply cleanly): $name" >&2
			MISSING=1
		else
			render_patch "$p" | patch -p1 >/dev/null && echo "  ✓ applied: $name"
		fi
	elif render_patch "$p" | patch -p1 -R --dry-run >/dev/null 2>&1; then
		echo "  ⊘ already applied: $name"
	else
		echo "  ✗ FAILED (context mismatch — dsh version likely changed, re-derive the patch): $name" >&2
		exit 1
	fi
done

if [ "$CHECK_ONLY" = "1" ]; then
	[ "${MISSING:-0}" = "1" ] && exit 1
	echo
	echo "All patches are in place."
	exit 0
fi

echo
echo "Done. Restart dsh to load patched code."
echo "  from a plain shell:   supervisorctl restart dsh"
echo "  from inside an agent running in dsh: use the restart-dsh skill's detached form"
echo "  (never run supervisorctl restart dsh directly from an agent's bash call)"
