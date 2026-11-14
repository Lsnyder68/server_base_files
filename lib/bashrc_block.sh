#!/usr/bin/env bash
# Shared helpers for the managed shell-configuration block.
#
# Sourced by install_base_apps.sh and by tests/test_bashrc_block.sh.
# No side effects at source time; every function takes explicit paths so it
# can be exercised against throwaway homes without root.

SERVER_BASE_VERSION="3"
SERVER_BASE_BEGIN='# >>> server-base (managed) >>>'
SERVER_BASE_END='# <<< server-base (managed) <<<'
SERVER_BASE_META_PREFIX='# server-base:'
SERVER_BASE_KEEP_BACKUPS=5
SERVER_BASE_PERMANENT_BACKUP_NAME='.bashrc.pre-server-base'
SERVER_BASE_BACKUP_DIR_NAME='.local/share/server-base/backups'

# SHA-256 of every `bashrc` bundle this project has shipped, newest first.
#
# A host flattened by an older release has one of these as its ~/.bashrc. A
# fixed table keeps recovery working from a tarball, a shallow clone, or a git
# worktree, where `git log` has no history to read. The bundle next to this
# script is added at run time as well, so a stale table cannot misclassify the
# copy that is actually deployed.
#
# Regenerate with tools/bundle-hashes.sh after editing `bashrc`;
# tests/test_bashrc_block.sh fails when the current bundle is missing.
SERVER_BASE_BUNDLE_HASHES="
5b30c64d56af7c75490f17c785e0902fbd21bd70dd61c0026d5fef838ff565b7
ead411c06b86e7b7e8d6a2e696adb21c7fc01a1b24d61e4efd7e704116d86800
f3fe0b6de4182d06ede8200db8bf109fdff3db12345d279b86f8ba393900aabe
52b2e5f3daca4471deb533f88af64b43936af082a3b96526446b1a732d41615c
b589212320bf8a9d927cded8c8fe96ebd007a9e10a3f5f37799dd0d19592870e
8fd330b73926acf87f0a28f30e8d14551583528cd349662e1deb1a3cd1631fe6
fb2d434dc27bc1ea9d325b1227e9f234cde7e2b794fc5dcabb8dc5eee1b01b0e
e12e4e0d3fbbccf00bb9e5b17be69d240613ea6651e2273826db22725bda63b2
4062ed8efd4ad0ee490b68ad95cb7c6482c4bffda45ed18d2693cb66e6d57b3f
"

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

# sb_strip_block <file> <out>
# Copy <file> to <out> with the managed block (markers included) removed. A
# file without markers is copied unchanged, byte for byte. Shared by
# sb_remove_block and by recovery, which must still recognise a flattened host
# after the block has been layered on top of it.
sb_strip_block() {
    local file="$1" out="$2"
    awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" '
        { line = $0; sub(/\r$/, "", line) }
        line == b { skipping = 1; next }
        skipping { if (line == e) skipping = 0; next }
        { print }
    ' "$file" > "$out"
}

# sb_bundle_hash_table <out> [repo-dir]
# Write one SHA-256 per line: the shipped-bundle table above plus the bundle in
# <repo-dir>, if there is one. Returns 1 when no hash is available at all.
sb_bundle_hash_table() {
    local out="$1" repo="${2:-}"
    : > "$out" || return 1
    # shellcheck disable=SC2086  # intentional word splitting of the table
    printf '%s\n' $SERVER_BASE_BUNDLE_HASHES >> "$out"
    if [ -n "$repo" ] && [ -r "$repo/bashrc" ]; then
        sb_hash_file "$repo/bashrc" >> "$out"
    fi
    sort -u -o "$out" "$out" 2>/dev/null || true
    [ -s "$out" ]
}

# sb_is_bundle_copy <file> [repo-dir]
# 0 when <file>, ignoring a managed block, is byte-identical to a shipped
# bundle; 1 when it is host content; 2 when it cannot be read or hashed.
sb_is_bundle_copy() {
    local file="$1" repo="${2:-}"
    local workdir table hash rc=1
    [ -r "$file" ] || return 2

    workdir=$(mktemp -d "${TMPDIR:-/tmp}/server-base.XXXXXX") || return 2
    table="$workdir/bundle-hashes"
    if sb_strip_block "$file" "$workdir/stripped" &&
       sb_bundle_hash_table "$table" "$repo"; then
        hash=$(sb_hash_file "$workdir/stripped")
        if [ -z "$hash" ]; then
            rc=2
        elif grep -qx "$hash" "$table" 2>/dev/null; then
            rc=0
        fi
    else
        rc=2
    fi

    rm -rf "$workdir"
    return "$rc"
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

# sb_ensure_dir <dir> [owner]
# Create <dir> and any missing parents. With a "user:group" owner and root
# privileges, only the directories we create are given that owner: existing
# ones are left exactly as they were, so a 700 ~/.local is neither widened nor
# re-chowned. Without root, or without an owner, this is a plain mkdir -p.
sb_ensure_dir() {
    local dir="$1" owner="${2:-}" cur="" user="" group=""
    local -a missing=()

    [ -n "$dir" ] || return 1
    [ -d "$dir" ] && return 0

    cur="$dir"
    while [ -n "$cur" ] && [ "$cur" != "/" ] && [ ! -d "$cur" ]; do
        missing=("$cur" "${missing[@]}")
        cur=$(dirname "$cur")
    done

    if [ -n "$owner" ] && [ "$(id -u)" -eq 0 ]; then
        user="${owner%%:*}"
        group="${owner#*:}"
        [ "$group" = "$owner" ] && group=""
    fi

    for cur in "${missing[@]}"; do
        if [ -z "$user" ]; then
            mkdir -- "$cur" 2>/dev/null || return 1
        elif [ -n "$group" ]; then
            install -d -m 755 -o "$user" -g "$group" -- "$cur" 2>/dev/null || return 1
        else
            install -d -m 755 -o "$user" -- "$cur" 2>/dev/null || return 1
        fi
    done
    return 0
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

# sb_rotate_backup <rc> <backup-dir> [owner]
# Rotating snapshots only; never touches the permanent copy.
sb_rotate_backup() {
    local rc="$1" backup_dir="$2" owner="${3:-}"
    [ -f "$rc" ] || return 0
    sb_ensure_dir "$backup_dir" "$owner" || return 1
    local name target
    name=$(sb_backup_name)
    target="$backup_dir/$name"
    # Avoid clobbering a backup from the same second.
    [ -e "$target" ] && target="${target}.$$"
    cp -p -- "$rc" "$target" 2>/dev/null || return 1
    sb_prune_backups "$backup_dir"
    return 0
}

# sb_backup_file <rc> <permanent-backup> <backup-dir> [owner]
# Keep one never-pruned copy of the original and a small rotating history.
sb_backup_file() {
    local rc="$1" permanent="$2" backup_dir="$3" owner="${4:-}"
    [ -f "$rc" ] || return 0

    if [ ! -e "$permanent" ]; then
        cp -p -- "$rc" "$permanent" 2>/dev/null || return 1
    fi

    sb_rotate_backup "$rc" "$backup_dir" "$owner"
}

# sb_write_atomic <source> <target>
# Preserve mode and ownership; restore SELinux context when possible.
sb_write_atomic() {
    local source="$1" target="$2"
    local dir mode owner tmp
    dir=$(dirname "$target")
    mode=$(sb_file_mode "$target")
    owner=$(sb_file_owner "$target")
    # A missing .bashrc has no owner to copy, so borrow the one from the
    # directory that will hold it. Without this, `sudo` leaves a root-owned
    # file in the user's home and the user cannot edit their own shell config.
    [ -n "$owner" ] || owner=$(sb_file_owner "$dir")

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

# sb_install_block <rc> <fragment> <permanent-backup> <backup-dir> [owner]
# Sets SB_RESULT to created|updated|unchanged and returns:
#   0 changed, 10 unchanged, 3 malformed markers, 1 error.
sb_install_block() {
    local rc="$1" fragment="$2" permanent="$3" backup_dir="$4" owner="${5:-}"
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

    if ! sb_backup_file "$rc" "$permanent" "$backup_dir" "$owner"; then
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

    if ! sb_strip_block "$rc" "$tmp"; then
        rm -rf "$workdir"
        return 1
    fi

    if ! sb_write_atomic "$tmp" "$rc"; then
        rm -rf "$workdir"
        return 1
    fi
    rm -rf "$workdir"
    return 0
}

# sb_preview_removal <rc>
# Print exactly the lines sb_remove_block would delete, without touching
# anything. Used by --dry-run --bashrc-uninstall.
sb_preview_removal() {
    local rc="$1" state bline eline
    read -r state bline eline <<EOF
$(sb_scan_markers "$rc")
EOF
    [ "$state" = "pair" ] || return 0
    sed -n "${bline},${eline}p" "$rc"
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

# sb_backup_sort_key <basename>
# Print the timestamp embedded in a backup name with its separators removed, so
# `bashrc.20240102-030405` and `.bashrc_20240102-03:04` can be sorted against
# each other. Fails for names this project did not create.
sb_backup_sort_key() {
    local name="$1" key=""
    case "$name" in
        bashrc.[0-9]*) key="${name#bashrc.}" ;;
        .bashrc_[0-9]*) key="${name#.bashrc_}" ;;
        *) return 1 ;;
    esac
    key=$(printf '%s' "$key" | tr -cd '0-9')
    [ -n "$key" ] || return 1
    printf '%s\n' "$key"
}

# sb_recovery_backup <rc> <repo-dir> <backup-dir> [legacy-dir]
# Print the newest backup that is not itself a copy of a shipped bashrc bundle.
# Used when a host's file was already overwritten by an older installer.
#
# The managed block is ignored when reading both the current file and the
# candidates, so a host stays recoverable after the block has been installed on
# top of a flattened file, and a candidate that is "bundle + old block" is still
# recognised as a bundle. Legacy-dir covers the old .bashrc_YYYYMMDD-HH:MM
# naming.
sb_recovery_backup() {
    local rc="$1" repo="$2" backup_dir="$3" legacy_dir="${4:-}"
    [ -r "$rc" ] || return 1

    local workdir
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/server-base.XXXXXX") || return 1

    if ! sb_bundle_hash_table "$workdir/bundle-hashes" "$repo"; then
        rm -rf "$workdir"
        return 1
    fi

    sb_strip_block "$rc" "$workdir/current" || {
        rm -rf "$workdir"
        return 1
    }
    local curhash
    curhash=$(sb_hash_file "$workdir/current")
    if [ -z "$curhash" ] || ! grep -qx "$curhash" "$workdir/bundle-hashes"; then
        rm -rf "$workdir"
        return 1
    fi

    {
        if [ -d "$backup_dir" ]; then
            find "$backup_dir" -maxdepth 1 -type f -name 'bashrc.[0-9]*' 2>/dev/null
        fi
        if [ -n "$legacy_dir" ] && [ -d "$legacy_dir" ]; then
            find "$legacy_dir" -maxdepth 1 -type f -name '.bashrc_[0-9]*' 2>/dev/null
        fi
    } > "$workdir/candidates"

    # Newest first, across both name schemes: neither directory may win just
    # because it was searched first.
    local candidate key
    : > "$workdir/ordered"
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        key=$(sb_backup_sort_key "${candidate##*/}") || continue
        printf '%s\t%s\n' "$key" "$candidate" >> "$workdir/ordered"
    done < "$workdir/candidates"
    sort -r "$workdir/ordered" > "$workdir/sorted" 2>/dev/null ||
        cp -- "$workdir/ordered" "$workdir/sorted"

    local found=""
    while IFS=$'\t' read -r key candidate; do
        [ -n "$candidate" ] || continue
        if ! sb_is_bundle_copy "$candidate" "$repo"; then
            found="$candidate"
            break
        fi
    done < "$workdir/sorted"

    rm -rf "$workdir"
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
    return 0
}
