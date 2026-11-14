#!/usr/bin/env bash
# Maintain SERVER_BASE_BUNDLE_HASHES in lib/bashrc_block.sh.
#
# Recovery has to recognise a `bashrc` bundle that an older release installed
# as a whole file. It cannot read that history from git: shipped copies run
# from tarballs, shallow clones, and worktrees, where `.git` may be a file or
# absent. The library therefore carries a fixed table, and this script
# regenerates it from git history plus the working-tree copy.
#
# Usage:
#   tools/bundle-hashes.sh           # print one hash per line
#   tools/bundle-hashes.sh --write   # rewrite the table in the library
#
# Run it after every change to `bashrc`. tests/test_bashrc_block.sh fails if
# the current bundle is missing from the table.
set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$ROOT/lib/bashrc_block.sh"

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | sed 's/.*= //'
    fi
}

hashes() {
    local rev seen=""
    if command -v git >/dev/null 2>&1 &&
       git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        # Newest first, matching the order of the table.
        for rev in $(git -C "$ROOT" log --format=%H -- bashrc 2>/dev/null); do
            local blob
            if blob=$(mktemp "${TMPDIR:-/tmp}/bashrc.XXXXXX"); then
                if git -C "$ROOT" show "$rev:bashrc" > "$blob" 2>/dev/null; then
                    local h
                    h=$(hash_file "$blob")
                    case " $seen " in
                        *" $h "*) ;;
                        *) printf '%s\n' "$h"; seen="$seen $h" ;;
                    esac
                fi
                rm -f "$blob"
            fi
        done
    fi

    local current
    current=$(hash_file "$ROOT/bashrc")
    case " $seen " in
        *" $current "*) ;;
        *) printf '%s\n' "$current" ;;
    esac
}

rewrite() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/bashrc_block.XXXXXX") || exit 1

    {
        awk -v hashes="$(hashes)" '
            /^SERVER_BASE_BUNDLE_HASHES="/ { inblock = 1; print; print hashes; next }
            inblock && /^"$/ { inblock = 0; print; next }
            inblock { next }
            { print }
        ' "$LIB"
    } > "$tmp" || { rm -f "$tmp"; exit 1; }

    mv -f "$tmp" "$LIB" || { rm -f "$tmp"; exit 1; }
    echo "Updated $LIB" >&2
}

case "${1:-}" in
    "") hashes ;;
    --write) rewrite ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Error: unknown option: $1" >&2; exit 2 ;;
esac
