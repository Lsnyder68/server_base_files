#!/usr/bin/env bash
# Tests for lib/bashrc_block.sh. No root required; every scenario uses a
# throwaway home directory.
#
# Run: bash tests/test_bashrc_block.sh

set -u
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/bashrc_block.sh
. "$SCRIPT_DIR/lib/bashrc_block.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name" "expected [$expected] got [$actual]"
    fi
}

assert_true() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name" "condition failed: $*"; fi
}

new_home() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/sb-test.XXXXXX")
    mkdir -p "$dir/.local/share/server-base/backups"
    printf '%s\n' "$dir"
}

write_fragment() {
    local path="$1"
    cat > "$path" <<'FRAG'
export SERVER_BASE_LOADED=1
alias sbhello='echo hello from server-base'
FRAG
}

# install <home> <fragment> [rc]
install() {
    local home="$1" frag="$2" rc="${3:-$1/.bashrc}"
    mkdir -p "$(dirname "$rc")"
    sb_install_block "$rc" "$frag" \
        "$home/$SERVER_BASE_PERMANENT_BACKUP_NAME" \
        "$home/$SERVER_BASE_BACKUP_DIR_NAME"
}

test_append_preserves_path() {
    local home frag rc
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    cat > "$rc" <<'RC'
# host specific
export PATH="/opt/vendor/bin:$PATH"
export JAVA_HOME=/opt/java
RC

    install "$home" "$frag"
    local rc_status=$?
    assert_eq "append: returns 0" 0 "$rc_status"
    assert_true "append: PATH kept" grep -q '/opt/vendor/bin' "$rc"
    assert_true "append: JAVA_HOME kept" grep -q 'JAVA_HOME=/opt/java' "$rc"
    assert_true "append: marker present" grep -qxF "$SERVER_BASE_BEGIN" "$rc"

    local path
    path=$(env -i HOME="$home" TERM=xterm bash -ic 'printf "%s" "$PATH"' 2>/dev/null)
    case "$path" in
        /opt/vendor/bin:*) pass "append: PATH order preserved in shell" ;;
        *) fail "append: PATH order preserved in shell" "got [$path]" ;;
    esac

    rm -rf "$home"
}

test_idempotent() {
    local home frag rc before after backups_before backups_after
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    printf 'export PATH="/opt/vendor/bin:$PATH"\n' > "$rc"

    install "$home" "$frag" >/dev/null
    before=$(sb_hash_file "$rc")
    backups_before=$(find "$home/$SERVER_BASE_BACKUP_DIR_NAME" -type f | wc -l)

    install "$home" "$frag" >/dev/null
    local status=$?
    after=$(sb_hash_file "$rc")
    backups_after=$(find "$home/$SERVER_BASE_BACKUP_DIR_NAME" -type f | wc -l)

    assert_eq "idempotent: second run returns 10" 10 "$status"
    assert_eq "idempotent: file unchanged" "$before" "$after"
    assert_eq "idempotent: no extra backup" "$backups_before" "$backups_after"

    rm -rf "$home"
}

test_non_interactive_silent() {
    local home frag rc out
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    : > "$rc"
    install "$home" "$frag" >/dev/null

    out=$(BASH_ENV="$rc" bash -c 'true' 2>&1)
    assert_eq "non-interactive: no output" "" "$out"

    out=$(bash -c 'type sbhello >/dev/null 2>&1 && echo defined || echo absent' 2>/dev/null)
    assert_eq "non-interactive: alias absent" "absent" "$out"

    out=$(env -i HOME="$home" TERM=xterm bash -ic 'alias sbhello >/dev/null 2>&1 && echo defined || echo absent' 2>/dev/null)
    assert_eq "interactive: alias present" "defined" "$out"

    rm -rf "$home"
}

test_set_u_safe() {
    local home frag rc out
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    : > "$rc"
    install "$home" "$frag" >/dev/null

    out=$(env -i HOME="$home" TERM=xterm bash -u -ic 'true' 2>&1 \
        | grep -v -e 'cannot set terminal process group' -e 'no job control' || true)
    assert_eq "set -u: no unbound variable error" "" "$out"

    out=$(env -i HOME="$home" bash --norc -u -c '. "$HOME/.bashrc"; true' 2>&1)
    assert_eq "set -u: sourcing non-interactively is clean" "" "$out"

    rm -rf "$home"
}

test_upgrade_replaces_block() {
    local home frag rc count
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    : > "$rc"
    install "$home" "$frag" >/dev/null

    # Simulate an older block: change version and body inside the markers.
    awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" '
        $0 == b { print; print "# server-base: version=1 sha256=deadbeef"; skip = 1; next }
        skip && $0 == e { skip = 0; print; next }
        skip { next }
        { print }
    ' "$rc" > "$rc.new" && mv "$rc.new" "$rc"

    install "$home" "$frag" >/dev/null
    count=$(grep -cxF "$SERVER_BASE_BEGIN" "$rc")
    assert_eq "upgrade: exactly one begin marker" 1 "$count"
    assert_true "upgrade: current version" grep -q "version=$SERVER_BASE_VERSION" "$rc"
    assert_true "upgrade: marker count matches" test "$(grep -cxF "$SERVER_BASE_END" "$rc")" -eq 1

    rm -rf "$home"
}

test_malformed_markers() {
    local home frag rc before after status
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    {
        printf '%s\n' "$SERVER_BASE_BEGIN"
        printf '%s\n' "$SERVER_BASE_BEGIN"
        printf 'echo broken\n'
    } > "$rc"
    before=$(sb_hash_file "$rc")

    install "$home" "$frag" >/dev/null 2>&1
    status=$?
    after=$(sb_hash_file "$rc")

    assert_eq "malformed: returns 3" 3 "$status"
    assert_eq "malformed: file untouched" "$before" "$after"

    rm -rf "$home"
}

test_mode_preserved() {
    local home frag rc mode
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    printf 'export FOO=1\n' > "$rc"
    chmod 600 "$rc"

    install "$home" "$frag" >/dev/null
    mode=$(stat -c '%a' "$rc")
    assert_eq "permissions: 600 stays 600" "600" "$mode"

    rm -rf "$home"
}

test_original_never_pruned() {
    local home frag rc i
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    printf 'export PATH="/opt/keepme:$PATH"\n' > "$rc"
    printf 'alias work="cd /srv"\n' > "$home/.bashrc_local"

    for i in 1 2 3 4 5 6 7 8 9 10; do
        # Force a change every run so rotating backups are exercised.
        printf '# run %s\n' "$i" >> "$rc"
        install "$home" "$frag" >/dev/null 2>&1
    done

    assert_true "preservation: permanent backup exists" test -f "$home/$SERVER_BASE_PERMANENT_BACKUP_NAME"
    assert_true "preservation: original PATH recoverable" grep -q '/opt/keepme' "$home/$SERVER_BASE_PERMANENT_BACKUP_NAME"
    assert_true "preservation: .bashrc_local untouched" test -f "$home/.bashrc_local"

    rm -rf "$home"
}

test_missing_trailing_newline() {
    local home frag rc
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    printf 'export PATH="/opt/x:$PATH"' > "$rc"   # no trailing newline

    install "$home" "$frag" >/dev/null
    assert_eq "newline: install succeeds" 0 "$?"
    assert_true "newline: marker is its own line" grep -qxF "$SERVER_BASE_BEGIN" "$rc"
    bash -n "$rc" && pass "newline: file parses" || fail "newline: file parses"

    rm -rf "$home"
}

test_uninstall_roundtrip() {
    local home frag rc body_before after
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    cat > "$rc" <<'RC'
export PATH="/opt/vendor/bin:$PATH"
alias ll='ls -l'
RC
    body_before=$(sb_hash_file "$rc")

    install "$home" "$frag" >/dev/null
    sb_remove_block "$rc"
    assert_eq "uninstall: returns 0" 0 "$?"

    # A trailing newline may have been added; compare after normalizing.
    after=$(sb_hash_file "$rc")
    assert_eq "uninstall: content restored" "$body_before" "$after"

    rm -rf "$home"
}

test_check_statuses() {
    local home frag rc status
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    printf 'export FOO=1\n' > "$rc"

    sb_check "$rc" "$frag"; status=$?
    assert_eq "check: not installed is 1" 1 "$status"

    install "$home" "$frag" >/dev/null
    sb_check "$rc" "$frag"; status=$?
    assert_eq "check: current is 0" 0 "$status"

    # Hand-edit inside the block.
    awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" '
        $0 == b { inblock = 1; print; next }
        inblock && $0 == e { inblock = 0; print; next }
        inblock { print $0 " # edited"; next }
        { print }
    ' "$rc" > "$rc.new" && mv "$rc.new" "$rc"
    sb_check "$rc" "$frag"; status=$?
    assert_eq "check: hand-edited is 2" 2 "$status"

    # Restore a clean block, then point at a different fragment.
    install "$home" "$frag" >/dev/null
    local frag2="$home/fragment2"
    printf 'export SERVER_BASE_LOADED=1\n# changed\n' > "$frag2"
    sb_check "$rc" "$frag2"; status=$?
    assert_eq "check: outdated is 1" 1 "$status"

    rm -rf "$home"
}

test_hand_edit_warns_and_preserves() {
    local home frag rc status
    home=$(new_home); frag="$home/fragment"; rc="$home/.bashrc"
    write_fragment "$frag"
    : > "$rc"
    install "$home" "$frag" >/dev/null

    awk -v b="$SERVER_BASE_BEGIN" -v e="$SERVER_BASE_END" '
        $0 == b { inblock = 1; print; next }
        inblock && $0 == e { inblock = 0; print; next }
        inblock { print $0 " # my edit"; next }
        { print }
    ' "$rc" > "$rc.new" && mv "$rc.new" "$rc"

    install "$home" "$frag" >/dev/null 2>&1
    status=$?
    assert_eq "hand-edit: reinstall succeeds" 0 "$status"
    assert_eq "hand-edit: reported as hand-edited" "hand-edited" "$SB_RESULT"

    # The edited copy must survive in a rotating backup.
    local found=1
    if grep -rq '# my edit' "$home/$SERVER_BASE_BACKUP_DIR_NAME" 2>/dev/null; then
        found=0
    fi
    assert_eq "hand-edit: edited copy backed up" 0 "$found"

    rm -rf "$home"
}

main() {
    test_append_preserves_path
    test_idempotent
    test_non_interactive_silent
    test_set_u_safe
    test_upgrade_replaces_block
    test_malformed_markers
    test_mode_preserved
    test_original_never_pruned
    test_missing_trailing_newline
    test_uninstall_roundtrip
    test_check_statuses
    test_hand_edit_warns_and_preserves

    echo ""
    printf '%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] || {
        printf 'failed: %s\n' "${FAILED_TESTS[*]}"
        return 1
    }
}

main "$@"
