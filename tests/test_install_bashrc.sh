#!/usr/bin/env bash
# End-to-end tests for install_bashrc() and its CLI helpers.
# Sources the installer (its main() only runs when executed directly), points
# HOME at a throwaway directory, and never touches the real home.
#
# Run: bash tests/test_install_bashrc.sh

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../install_base_apps.sh
. "$ROOT/install_base_apps.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name" "expected [$expected] got [$actual]"; fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "missing [$needle]" ;;
    esac
}

# Sets TEST_HOME in the current shell (not a subshell, so globals stick).
new_env() {
    TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/sb-it.XXXXXX")
    HOME="$TEST_HOME"
    TARGET_USER=""
    export HOME
    LOG_FILE="$TEST_HOME/install.log"
    DRY_RUN=false
    ASSUME_YES=true
    BASHRC_CHECK_ONLY=false
    BASHRC_UNINSTALL=false
    RESTORE_BASHRC=false
}

test_install_and_check() {
    local home out status
    new_env; home=$TEST_HOME
    cat > "$home/.bashrc" <<'RC'
export PATH="/opt/vendor/bin:$PATH"
alias work='cd /srv'
RC

    out=$(install_bashrc 2>&1); status=$?
    assert_eq "install: succeeds" 0 "$status"
    assert_contains "install: reports the block" "$out" "Added the server-base block"
    assert_contains "install: PATH kept" "$(cat "$home/.bashrc")" "/opt/vendor/bin"
    assert_eq "install: original backed up" 0 "$(test -f "$home/$SERVER_BASE_PERMANENT_BACKUP_NAME"; echo $?)"

    bashrc_check_cmd >/dev/null 2>&1; status=$?
    assert_eq "check: current after install" 0 "$status"

    out=$(install_bashrc 2>&1); status=$?
    assert_eq "install: second run is a no-op" 0 "$status"
    assert_contains "install: says nothing to do" "$out" "nothing to do"

    rm -rf "$home"
}

test_dry_run_diff() {
    local home out
    new_env; home=$TEST_HOME
    printf 'export PATH="/opt/x:$PATH"\n' > "$home/.bashrc"
    DRY_RUN=true
    out=$(install_bashrc 2>&1)
    assert_contains "dry-run: mentions the target" "$out" "Would install the server-base block"
    assert_contains "dry-run: shows a diff" "$out" "server-base (managed)"
    assert_eq "dry-run: file untouched" "export PATH=\"/opt/x:\$PATH\"" "$(cat "$home/.bashrc")"
    DRY_RUN=false
    rm -rf "$home"
}

test_uninstall_cli() {
    local home out status
    new_env; home=$TEST_HOME
    printf 'export PATH="/opt/x:$PATH"\n' > "$home/.bashrc"
    install_bashrc >/dev/null 2>&1

    out=$(bashrc_uninstall_cmd 2>&1); status=$?
    assert_eq "uninstall: succeeds" 0 "$status"
    assert_contains "uninstall: reports removal" "$out" "Removed the server-base block"
    assert_eq "uninstall: PATH kept" "export PATH=\"/opt/x:\$PATH\"" "$(cat "$home/.bashrc")"

    bashrc_check_cmd >/dev/null 2>&1; status=$?
    assert_eq "check: reports not installed after uninstall" 1 "$status"

    rm -rf "$home"
}

test_malformed_refuses() {
    local home before after out status
    new_env; home=$TEST_HOME
    {
        printf '%s\n' "$SERVER_BASE_BEGIN"
        printf '%s\n' "$SERVER_BASE_BEGIN"
        printf 'echo hi\n'
    } > "$home/.bashrc"
    before=$(sb_hash_file "$home/.bashrc")

    out=$(install_bashrc 2>&1); status=$?
    after=$(sb_hash_file "$home/.bashrc")
    assert_eq "malformed: install fails" 1 "$status"
    assert_contains "malformed: explains why" "$out" "malformed"
    assert_eq "malformed: file untouched" "$before" "$after"

    rm -rf "$home"
}

test_symlink_target() {
    local home dot out
    new_env; home=$TEST_HOME
    dot="$home/dotfiles"
    mkdir -p "$dot"
    printf 'export PATH="/opt/dot:$PATH"\n' > "$dot/bashrc"
    ln -s "$dot/bashrc" "$home/.bashrc"

    out=$(install_bashrc 2>&1)
    assert_contains "symlink: updates the target" "$out" "Added the server-base block"
    assert_eq "symlink: link still a symlink" 0 "$(test -L "$home/.bashrc"; echo $?)"
    assert_contains "symlink: target has block" "$(cat "$dot/bashrc")" "$SERVER_BASE_BEGIN"
    assert_eq "symlink: backup outside dotfiles" 0 "$(test -f "$home/$SERVER_BASE_PERMANENT_BACKUP_NAME"; echo $?)"
    assert_eq "symlink: no backup inside dotfiles" 0 "$(ls "$dot" | grep -c '^bashrc\.' )"

    rm -rf "$home"
}

test_recovery_of_flattened_host() {
    local home old_bundle out status candidate rev
    new_env; home=$TEST_HOME

    # Simulate a host flattened by an older release: current .bashrc is an
    # exact copy of a bundle that shipped earlier. Fall back to the current
    # bundle when the test runs from a tarball without git history.
    old_bundle="$home/old-bashrc"
    if command -v git >/dev/null 2>&1 &&
       git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        rev=$(git -C "$ROOT" log --format=%H -- bashrc | tail -n 1)
        git -C "$ROOT" show "$rev:bashrc" > "$old_bundle" 2>/dev/null || true
    fi
    [ -s "$old_bundle" ] || cp "$ROOT/bashrc" "$old_bundle"
    cp "$old_bundle" "$home/.bashrc"

    # A legacy backup still holds the real host content.
    printf 'export PATH="/opt/legacy:$PATH"\n' > "$home/.bashrc_20240101-10:00"

    candidate=$(sb_recovery_backup "$home/.bashrc" "$ROOT" \
        "$home/$SERVER_BASE_BACKUP_DIR_NAME" "$home" 2>/dev/null || true)
    assert_eq "recovery: finds the legacy backup" "$home/.bashrc_20240101-10:00" "$candidate"

    out=$(bashrc_restore_cmd 2>&1); status=$?
    assert_eq "recovery: restore succeeds" 0 "$status"
    assert_contains "recovery: restored PATH" "$(cat "$home/.bashrc")" "/opt/legacy"
    assert_contains "recovery: suggests a re-run" "$out" "Re-run this installer"

    out=$(install_bashrc 2>&1); status=$?
    assert_eq "recovery: install succeeds after restore" 0 "$status"
    assert_contains "recovery: block layers on restored file" "$out" "Added the server-base block"
    assert_contains "recovery: restored PATH survives" "$(cat "$home/.bashrc")" "/opt/legacy"

    rm -rf "$home"
}

test_dry_run_changes_nothing() {
    local home before out status
    new_env; home=$TEST_HOME
    printf 'export PATH="/opt/x:$PATH"\n' > "$home/.bashrc"
    install_bashrc >/dev/null 2>&1

    # --bashrc-uninstall
    before=$(sb_hash_file "$home/.bashrc")
    DRY_RUN=true
    out=$(bashrc_uninstall_cmd 2>&1); status=$?
    assert_eq "dry-run uninstall: succeeds" 0 "$status"
    assert_contains "dry-run uninstall: says what it would do" "$out" "Would remove this block"
    assert_eq "dry-run uninstall: file untouched" "$before" "$(sb_hash_file "$home/.bashrc")"

    # --restore-bashrc on a flattened host
    cp "$ROOT/bashrc" "$home/.bashrc"
    printf 'export PATH="/opt/legacy:$PATH"\n' > "$home/.bashrc_20240101-10:00"
    before=$(sb_hash_file "$home/.bashrc")
    out=$(bashrc_restore_cmd 2>&1); status=$?
    assert_eq "dry-run restore: succeeds" 0 "$status"
    assert_contains "dry-run restore: says what it would do" "$out" "Would replace"
    assert_eq "dry-run restore: file untouched" "$before" "$(sb_hash_file "$home/.bashrc")"

    # A real install would stop instead of layering on a bundle copy.
    out=$(install_bashrc 2>&1); status=$?
    assert_eq "dry-run flattened: install succeeds" 0 "$status"
    assert_contains "dry-run flattened: a real run would stop" "$out" "would stop here"
    assert_eq "dry-run flattened: file untouched" "$before" "$(sb_hash_file "$home/.bashrc")"

    DRY_RUN=false
    rm -rf "$home"
}

test_install_refuses_flattened_host() {
    local home before out status
    new_env; home=$TEST_HOME
    cp "$ROOT/bashrc" "$home/.bashrc"
    printf 'export PATH="/opt/legacy:$PATH"\n' > "$home/.bashrc_20240101-10:00"
    before=$(sb_hash_file "$home/.bashrc")

    out=$(install_bashrc 2>&1); status=$?
    assert_eq "flattened: install refuses" 1 "$status"
    assert_contains "flattened: names the restore command" "$out" "--restore-bashrc"
    assert_eq "flattened: file untouched" "$before" "$(sb_hash_file "$home/.bashrc")"
    assert_eq "flattened: permanent backup not seeded from a bundle" 1 \
        "$(test -e "$home/$SERVER_BASE_PERMANENT_BACKUP_NAME"; echo $?)"

    rm -rf "$home"
}

test_restore_survives_pruning() {
    local home backup out status i
    new_env; home=$TEST_HOME
    backup="$home/$SERVER_BASE_BACKUP_DIR_NAME"
    mkdir -p "$backup"
    cp "$ROOT/bashrc" "$home/.bashrc"

    # The only good copy is older than five bundle copies, so rotating the
    # current file during the restore prunes it before it can be read.
    printf 'export PATH="/opt/legacy:$PATH"\n' > "$backup/bashrc.20240101-000000"
    for i in 1 2 3 4 5; do
        cp "$ROOT/bashrc" "$backup/bashrc.2025010$i-000000"
    done

    out=$(bashrc_restore_cmd 2>&1); status=$?
    assert_eq "restore: survives pruning of the oldest candidate" 0 "$status"
    assert_contains "restore: real content restored" \
        "$(cat "$home/.bashrc")" "/opt/legacy"

    rm -rf "$home"
}

test_restore_after_block_installed() {
    local home out status
    new_env; home=$TEST_HOME
    cp "$ROOT/bashrc" "$home/.bashrc"
    {
        printf '%s\n' "$SERVER_BASE_BEGIN"
        printf '# server-base: version=2 sha256=deadbeef\n'
        printf 'export SERVER_BASE_LOADED=1\n'
        printf '%s\n' "$SERVER_BASE_END"
    } >> "$home/.bashrc"
    printf 'export PATH="/opt/legacy:$PATH"\n' > "$home/.bashrc_20240101-10:00"

    out=$(bashrc_restore_cmd 2>&1); status=$?
    assert_eq "restore: works after the block was installed" 0 "$status"
    assert_contains "restore: managed block is gone" \
        "$(grep -cxF "$SERVER_BASE_BEGIN" "$home/.bashrc")" "0"
    assert_contains "restore: real content back" "$(cat "$home/.bashrc")" "/opt/legacy"

    rm -rf "$home"
}

main() {
    test_install_and_check
    test_dry_run_diff
    test_uninstall_cli
    test_malformed_refuses
    test_symlink_target
    test_recovery_of_flattened_host
    test_dry_run_changes_nothing
    test_install_refuses_flattened_host
    test_restore_survives_pruning
    test_restore_after_block_installed

    echo ""
    printf '%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] || {
        printf 'failed: %s\n' "${FAILED_TESTS[*]}"
        return 1
    }
}

main "$@"
