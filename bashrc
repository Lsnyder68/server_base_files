# server-base shell fragment
#
# Sourced from a managed block inside ~/.bashrc. Keep this file free of
# distro-specific boilerplate (prompt setup, dircolors, completion guards,
# ~/.bash_aliases sourcing): the host's own skeleton already does those, and
# replacing them is what used to break tab completion and RHEL's /etc/bashrc.
#
# Everything here must be silent and safe under `set -u`.

# Raise history limits, never lower them. `:=` does not work here: interactive
# bash always pre-sets HISTSIZE (500).
#
# A value we cannot read as a positive number is left exactly as the host set
# it. Bash treats an unset, empty or non-numeric HISTFILESIZE as "never
# truncate" and a negative one as "unlimited", so clamping it would delete
# history that has no other copy. A deliberate 0 (history disabled) is honoured
# for the same reason. HISTSIZE is memory-only, but the same rule keeps a host
# from having a privacy setting silently reversed.
if ! declare -p HISTSIZE 2>/dev/null | grep -q '^declare -[^ ]*r'; then
    case "${HISTSIZE:-}" in
        ''|*[!0-9]*) ;;                                 # unset or unlimited
        0) ;;                                           # disabled on purpose
        *) if [ "$HISTSIZE" -lt 10000 ]; then HISTSIZE=10000; fi ;;
    esac
fi

# Do not invent a HISTFILESIZE where the host has none: setting one introduces
# truncation at shell exit, which a host with an unset value does not have.
if ! declare -p HISTFILESIZE 2>/dev/null | grep -q '^declare -[^ ]*r'; then
    case "${HISTFILESIZE:-}" in
        ''|*[!0-9]*) ;;                                 # never truncated
        0) ;;                                           # no history file
        *) if [ "$HISTFILESIZE" -lt 20000 ]; then HISTFILESIZE=20000; fi ;;
    esac
fi

# Append the history options we want without discarding host policy.
if ! declare -p HISTCONTROL 2>/dev/null | grep -q '^declare -[^ ]*r'; then
    case ":${HISTCONTROL:-}:" in
        *:ignoredups:*|*:ignoreboth:*) ;;
        *) HISTCONTROL="${HISTCONTROL:+$HISTCONTROL:}ignoredups" ;;
    esac
    case ":${HISTCONTROL:-}:" in
        *:ignorespace:*|*:ignoreboth:*) ;;
        *) HISTCONTROL="${HISTCONTROL:+$HISTCONTROL:}ignorespace" ;;
    esac
fi

shopt -s histappend
shopt -s checkwinsize

# Standardize the prompt only when the host still has bash's bare default,
# so a custom or distro prompt is left alone.
case "${PS1:-}" in
    '\s-\v\$ '*)
        PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
        ;;
esac

# Helpful aliases. `ld` is deliberately absent: it shadows the GNU linker.
alias hs='history | grep'
alias octal='stat --printf="%A\t%a\t%h\t%U\t%G\t%s\t%.19y\t%n\n" * | numfmt --to=iec-i --field=6 --delimiter="" --suffix=B'

# Debian/Ubuntu name the binaries batcat/fdfind; other distros use bat/fd.
if command -v batcat >/dev/null 2>&1; then
    alias bat='batcat'
fi
if command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

# Prefer eza for ls when available.
if command -v eza >/dev/null 2>&1; then
    alias ls='eza -a --long --group-directories-first --octal-permissions --git'
    alias ll='eza -a --long --group-directories-first --octal-permissions --git'
    alias la='eza -a --long --all'
    alias l='eza -a --long --all --group-directories-first'
fi

# Initialize optional tools once, even if the host already does so elsewhere.
if command -v mcfly >/dev/null 2>&1 && [ -z "${MCFLY_SHELL_INIT:-}" ]; then
    eval "$(mcfly init bash)"
    MCFLY_SHELL_INIT=1
fi

if command -v zoxide >/dev/null 2>&1 && [ -z "${ZOXIDE_SHELL_INIT:-}" ]; then
    eval "$(zoxide init bash)"
    ZOXIDE_SHELL_INIT=1
fi

# Sentinel used by `install_base_apps.sh --bashrc-check` and login-shell tests.
SERVER_BASE_LOADED=1
