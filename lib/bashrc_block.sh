#!/usr/bin/env bash
# Shared helpers for the managed shell-configuration block.
#
# Sourced by install_base_apps.sh and by tests/test_bashrc_block.sh.
# No side effects at source time; every function takes explicit paths so it
# can be exercised against throwaway homes without root.

SERVER_BASE_VERSION="2"
SERVER_BASE_BEGIN='# >>> server-base (managed) >>>'
SERVER_BASE_END='# <<< server-base (managed) <<<'
SERVER_BASE_META_PREFIX='# server-base:'
SERVER_BASE_KEEP_BACKUPS=5
SERVER_BASE_PERMANENT_BACKUP_NAME='.bashrc.pre-server-base'
SERVER_BASE_BACKUP_DIR_NAME='.local/share/server-base/backups'

# sb_hash_file <file>
# Print the SHA-256 of a file, using whichever tool the host provides.
sb_hash_file() {
    local file="$1" out=""
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        out=$(openssl dgst -sha256 "$file" 2>/dev/null | sed 's/.*= //')
    fi
    printf '%s\n' "$out"
}

# sb_render_block <fragment> <out>
# Render the managed block to <out>.
#
# Markers stay version-free so a future version still finds them. The version
# and a hash of the block body live on an inner line, which separates "bundle
# changed" drift from "someone edited inside the block" drift.
#
# The body is wrapped in an interactive guard rather than a bare `return` so
# that host overrides placed after the block still run, and so nothing is
# printed when BASH_ENV points at the file.
sb_render_block() {
    local fragment="$1" out="$2"
    local body="${out}.body" inner="${out}.inner" hash=""

    if [ ! -r "$fragment" ]; then
        return 1
    fi

    {
        printf '%s\n' "$SERVER_BASE_BEGIN"
        printf 'if [[ $- == *i* ]]; then\n'
        cat "$fragment" || return 1
        printf 'fi\n'
        printf '%s\n' "$SERVER_BASE_END"
    } > "$body" || return 1

    # Hash only the body (markers excluded), matching what sb_block_body
    # extracts later so drift detection compares like with like.
    sed '1d;$d' "$body" > "$inner" || {
        rm -f "$body" "$inner"
        return 1
    }
    hash=$(sb_hash_file "$inner")
    rm -f "$inner"
    if [ -z "$hash" ]; then
        rm -f "$body"
        return 1
    fi

    {
        head -n 1 "$body" || return 1
        printf '%s version=%s sha256=%s\n' \
            "$SERVER_BASE_META_PREFIX" "$SERVER_BASE_VERSION" "$hash"
        tail -n +2 "$body" || return 1
    } > "$out" || {
        rm -f "$body"
        return 1
    }

    rm -f "$body"
    return 0
}

# sb_scan_markers <file>
# Print "<state> <begin-line> <end-line>".
# state is one of: none, pair, malformed.
sb_scan_markers() {
    local file="$1"
    if [ ! -e "$file" ]; then
        printf 'none 0 0\n'
        return 0
    fi
    awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" '
        { line = $0; sub(/\r$/, "", line) }
        line == b { bcount++; bline = NR }
        line == e { ecount++; eline = NR }
        END {
            if (bcount == 0 && ecount == 0) {
                print "none 0 0"
            } else if (bcount == 1 && ecount == 1 && bline < eline) {
                printf "pair %d %d\n", bline, eline
            } else {
                printf "malformed %d %d\n", bline + 0, eline + 0
            }
        }
    ' "$file"
}

# sb_block_body <file> <out>
# Extract the block body without the version/hash line, so the hash can be
# recomputed the same way it was created.
sb_block_body() {
    local file="$1" out="$2"
    awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" \
        -v m="$SERVER_BASE_META_PREFIX" '
        { line = $0; sub(/\r$/, "", line) }
        line == b { inblock = 1; next }
        inblock && line == e { inblock = 0; next }
        inblock {
            if (index(line, m) == 1) next
            print line
        }
    ' "$file" > "$out"
}

# sb_block_meta <file>
# Print "version=<v> sha256=<h>" from the block meta line, if present.
sb_block_meta() {
    local file="$1"
    awk -v m="$SERVER_BASE_META_PREFIX" '
        { line = $0; sub(/\r$/, "", line) }
        index(line, m) == 1 {
            sub("^" m "[ \t]*", "", line)
            print line
            exit
        }
    ' "$file"
}

# sb_meta_value <meta-text> <key>
sb_meta_value() {
    local meta="$1" key="$2" token
    for token in $meta; do
        case "$token" in
            "$key"=*) printf '%s\n' "${token#*=}"; return 0 ;;
        esac
    done
    return 1
}

sb_file_mode() {
    local file="$1" mode=""
    mode=$(stat -c '%a' "$file" 2>/dev/null || true)
    [ -n "$mode" ] || mode="644"
    printf '%s\n' "$mode"
}

sb_file_owner() {
    local file="$1" owner=""
    owner=$(stat -c '%u:%g' "$file" 2>/dev/null || true)
    printf '%s\n' "$owner"
}

sb_backup_name() {
    printf 'bashrc.%s\n' "$(date '+%Y%m%d-%H%M%S')"
}

# sb_prune_backups <dir>
# Only touch names this script creates: bashrc.<digits>. User files such as
# .bashrc_local or .bashrc_work never match.
sb_prune_backups() {
    local dir="$1" old count=0
    [ -d "$dir" ] || return 0
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        count=$((count + 1))
        if [ "$count" -gt "$SERVER_BASE_KEEP_BACKUPS" ]; then
            rm -f -- "$old"
        fi
    done <<EOF
$(find "$dir" -maxdepth 1 -type f -name 'bashrc.[0-9]*' 2>/dev/null | sort -r)
EOF
}

# sb_rotate_backup <rc> <backup-dir>
# Rotating snapshots only; never touches the permanent copy.
sb_rotate_backup() {
    local rc="$1" backup_dir="$2"
    [ -f "$rc" ] || return 0
    mkdir -p -- "$backup_dir" 2>/dev/null || return 1
    local name target
    name=$(sb_backup_name)
    target="$backup_dir/$name"
    # Avoid clobbering a backup from the same second.
    [ -e "$target" ] && target="${target}.$$"
    cp -p -- "$rc" "$target" 2>/dev/null || return 1
    sb_prune_backups "$backup_dir"
    return 0
}

# sb_backup_file <rc> <permanent-backup> <backup-dir>
# Keep one never-pruned copy of the original and a small rotating history.
sb_backup_file() {
    local rc="$1" permanent="$2" backup_dir="$3"
    [ -f "$rc" ] || return 0

    if [ ! -e "$permanent" ]; then
        cp -p -- "$rc" "$permanent" 2>/dev/null || return 1
    fi

    sb_rotate_backup "$rc" "$backup_dir"
}

# sb_write_atomic <source> <target>
# Preserve mode and ownership; restore SELinux context when possible.
sb_write_atomic() {
    local source="$1" target="$2"
    local dir mode owner tmp
    dir=$(dirname "$target")
    mode=$(sb_file_mode "$target")
    owner=$(sb_file_owner "$target")

    tmp=$(mktemp "$dir/.bashrc.tmp.XXXXXX") || return 1
    if ! cat "$source" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    if [ -n "$owner" ] && [ "$(id -u)" -eq 0 ]; then
        chown "$owner" "$tmp" 2>/dev/null || true
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$target" >/dev/null 2>&1 || true
    fi
    return 0
}

# sb_install_block <rc> <fragment> <permanent-backup> <backup-dir>
# Sets SB_RESULT to created|updated|unchanged and returns:
#   0 changed, 10 unchanged, 3 malformed markers, 1 error.
sb_install_block() {
    local rc="$1" fragment="$2" permanent="$3" backup_dir="$4"
    local state bline eline
    read -r state bline eline <<EOF
$(sb_scan_markers "$rc")
EOF

    SB_RESULT="unchanged"
    case "$state" in
        malformed) return 3 ;;
        none|pair) ;;
        *) return 3 ;;
    esac

    local workdir rendered newbody body oldbody oldhash newhash stored_version stored_hash
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/server-base.XXXXXX") || return 1
    rendered="$workdir/rendered"
    newbody="$workdir/newbody.body"
    body="$workdir/body"
    oldbody="$workdir/oldbody"

    if ! sb_render_block "$fragment" "$rendered"; then
        rm -rf "$workdir"
        return 1
    fi
    sb_block_body "$rendered" "$newbody"
    newhash=$(sb_hash_file "$newbody")

    if [ "$state" = "pair" ]; then
        sb_block_body "$rc" "$oldbody"
        oldhash=$(sb_hash_file "$oldbody")
        local meta
        meta=$(sb_block_meta "$rc")
        stored_version=$(sb_meta_value "$meta" version || true)
        stored_hash=$(sb_meta_value "$meta" sha256 || true)

        if [ -n "$oldhash" ] && [ "$oldhash" = "$newhash" ] &&
           [ "$stored_version" = "$SERVER_BASE_VERSION" ] &&
           [ "$stored_hash" = "$newhash" ]; then
            rm -rf "$workdir"
            return 10
        fi
        # Someone edited inside the block if the body no longer matches the
        # hash recorded when it was written.
        if [ -n "$stored_hash" ] && [ "$oldhash" != "$stored_hash" ]; then
            SB_RESULT="hand-edited"
        fi
    fi

    if ! sb_backup_file "$rc" "$permanent" "$backup_dir"; then
        rm -rf "$workdir"
        return 1
    fi

    local tmp
    tmp="$workdir/newrc"

    if [ "$state" = "none" ]; then
        if [ -s "$rc" ] && [ -n "$(tail -c 1 "$rc" 2>/dev/null)" ]; then
            # File does not end in a newline; add one so the marker is a
            # valid comment line.
            cat "$rc" > "$tmp" || { rm -rf "$workdir"; return 1; }
            printf '\n' >> "$tmp"
        else
            cat "$rc" > "$tmp" 2>/dev/null || : > "$tmp"
        fi
        cat "$rendered" >> "$tmp" || { rm -rf "$workdir"; return 1; }
    else
        awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" \
            -v blockfile="$rendered" '
            { line = $0; sub(/\r$/, "", line) }
            line == b && !skipping {
                while ((getline l < blockfile) > 0) print l
                close(blockfile)
                skipping = 1
                next
            }
            skipping {
                if (line == e) skipping = 0
                next
            }
            { print }
        ' "$rc" > "$tmp" || { rm -rf "$workdir"; return 1; }
    fi

    if ! bash -n "$tmp" 2>/dev/null; then
        echo "Error: generated .bashrc failed syntax validation; leaving $rc unchanged." >&2
        rm -rf "$workdir"
        return 1
    fi

    if ! sb_write_atomic "$tmp" "$rc"; then
        rm -rf "$workdir"
        return 1
    fi

    if [ "$SB_RESULT" = "hand-edited" ]; then
        SB_RESULT="hand-edited"
    elif [ "$state" = "none" ]; then
        SB_RESULT="created"
    else
        SB_RESULT="updated"
    fi

    rm -rf "$workdir"
    return 0
}

# sb_remove_block <rc>
# 0 removed, 10 nothing to remove, 3 malformed, 1 error.
sb_remove_block() {
    local rc="$1" state bline eline
    read -r state bline eline <<EOF
$(sb_scan_markers "$rc")
EOF
    case "$state" in
        none) return 10 ;;
        malformed) return 3 ;;
    esac

    local workdir tmp
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/server-base.XXXXXX") || return 1
    tmp="$workdir/newrc"

    awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" '
        { line = $0; sub(/\r$/, "", line) }
        line == b { skipping = 1; next }
        skipping { if (line == e) skipping = 0; next }
        { print }
    ' "$rc" > "$tmp" || { rm -rf "$workdir"; return 1; }

    if ! sb_write_atomic "$tmp" "$rc"; then
        rm -rf "$workdir"
        return 1
    fi
    rm -rf "$workdir"
    return 0
}

# sb_check <rc> <fragment>
# 0 current, 1 outdated/not installed, 2 hand-edited, 3 malformed.
sb_check() {
    local rc="$1" fragment="$2" state bline eline
    read -r state bline eline <<EOF
$(sb_scan_markers "$rc")
EOF
    case "$state" in
        malformed) return 3 ;;
        none) return 1 ;;
    esac

    local workdir rendered newbody body oldbody oldhash newhash meta sv sh
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/server-base.XXXXXX") || return 1
    rendered="$workdir/rendered"
    newbody="$workdir/newbody"
    body="$workdir/body"
    oldbody="$workdir/oldbody"

    if ! sb_render_block "$fragment" "$rendered"; then
        rm -rf "$workdir"
        return 1
    fi
    sb_block_body "$rendered" "$newbody"
    newhash=$(sb_hash_file "$newbody")

    sb_block_body "$rc" "$oldbody"
    oldhash=$(sb_hash_file "$oldbody")
    meta=$(sb_block_meta "$rc")
    sv=$(sb_meta_value "$meta" version || true)
    sh=$(sb_meta_value "$meta" sha256 || true)

    rm -rf "$workdir"

    if [ -n "$sh" ] && [ "$oldhash" != "$sh" ]; then
        return 2
    fi
    if [ "$sv" != "$SERVER_BASE_VERSION" ] || [ "$oldhash" != "$newhash" ]; then
        return 1
    fi
    return 0
}

# sb_preview_diff <rc> <fragment>
# Print what a run would change, without touching anything.
sb_preview_diff() {
    local rc="$1" fragment="$2"
    local workdir rendered state bline eline
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/server-base.XXXXXX") || return 1
    rendered="$workdir/rendered"

    if ! sb_render_block "$fragment" "$rendered"; then
        rm -rf "$workdir"
        return 1
    fi

    read -r state bline eline <<EOF
$(sb_scan_markers "$rc")
EOF

    local proposed="$workdir/proposed"
    if [ "$state" = "pair" ]; then
        awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" \
            -v blockfile="$rendered" '
            { line = $0; sub(/\r$/, "", line) }
            line == b && !skipping {
                while ((getline l < blockfile) > 0) print l
                close(blockfile)
                skipping = 1
                next
            }
            skipping { if (line == e) skipping = 0; next }
            { print }
        ' "$rc" > "$proposed"
    else
        cat "$rc" > "$proposed" 2>/dev/null || : > "$proposed"
        [ -s "$proposed" ] && [ -n "$(tail -c 1 "$proposed" 2>/dev/null)" ] && printf '\n' >> "$proposed"
        cat "$rendered" >> "$proposed"
    fi

    if diff -u --label "$rc (current)" --label "$rc (proposed)" "$rc" "$proposed" 2>/dev/null; then
        :
    fi
    rm -rf "$workdir"
    return 0
}

# sb_recovery_backup <rc> <repo-dir> <backup-dir> [legacy-dir]
# Print the newest backup that is not itself a copy of the bundled bashrc.
# Used when a host's file was already overwritten by an older installer.
# Legacy-dir covers the old .bashrc_YYYYMMDD-HH:MM naming.
sb_recovery_backup() {
    local rc="$1" repo="$2" backup_dir="$3" legacy_dir="${4:-}"
    [ -r "$rc" ] || return 1

    local workdir
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/server-base.XXXXXX") || return 1

    # Hash every historical version of the bundle in this repo.
    : > "$workdir/bundle-hashes"
    if command -v git >/dev/null 2>&1 && [ -d "$repo/.git" ]; then
        local rev
        for rev in $(git -C "$repo" log --format=%H -- bashrc 2>/dev/null); do
            if git -C "$repo" show "$rev:bashrc" > "$workdir/rev" 2>/dev/null; then
                sb_hash_file "$workdir/rev" >> "$workdir/bundle-hashes"
            fi
        done
    fi
    local curhash
    curhash=$(sb_hash_file "$rc")
    if [ -s "$workdir/bundle-hashes" ]; then
        if ! grep -qx "$curhash" "$workdir/bundle-hashes" 2>/dev/null; then
            rm -rf "$workdir"
            return 1
        fi
    else
        rm -rf "$workdir"
        return 1
    fi

    local candidate found=""
    {
        [ -d "$backup_dir" ] && find "$backup_dir" -maxdepth 1 -type f -name 'bashrc.[0-9]*' 2>/dev/null
        [ -n "$legacy_dir" ] && [ -d "$legacy_dir" ] && \
            find "$legacy_dir" -maxdepth 1 -type f -name '.bashrc_[0-9]*' 2>/dev/null
    } | while IFS= read -r candidate; do
        local h
        h=$(sb_hash_file "$candidate")
        if ! grep -qx "$h" "$workdir/bundle-hashes" 2>/dev/null; then
            printf '%s\n' "$candidate"
            break
        fi
    done > "$workdir/candidate"

    found=$(head -n 1 "$workdir/candidate" 2>/dev/null)
    rm -rf "$workdir"
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
    return 0
}
