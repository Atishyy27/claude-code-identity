#!/usr/bin/env sh
# cc - Claude Code multi-identity launcher (macOS / Linux)
#
# Source this from your shell rc so `ccuse` can export into the CURRENT shell:
#     . "$HOME/.config/cc/cc.sh"
#
# Commands:
#   cc [id] [args...]   launch claude as <id> (default: the current default id)
#   ccuse <id>          make <id> the persistent default (bare `claude` too)
#   ccwho               list identities, login state, and which is default
#   ccnew <id> [dir]    register a NEW identity (explicit, so typos can't create one)
#   ccrm <id>           unregister an identity (never touches the shared store)
#
# Identity is per-process: Claude Code reads CLAUDE_CONFIG_DIR once at launch,
# so a running session can never change account. Use `cc <id> --resume`.

# This file defines shell functions, so it must be SOURCED. Executing it would
# define them in a subshell that exits immediately - silently doing nothing.
# Note zsh sets $0 to the file when sourcing (unlike bash), so $0 alone is not
# a reliable test; use each shell's own signal.
_cc_sourced=0
if [ -n "$ZSH_VERSION" ]; then
    case $ZSH_EVAL_CONTEXT in *file*) _cc_sourced=1 ;; esac
elif [ -n "$BASH_VERSION" ]; then
    # shellcheck disable=SC3028  # only reached when running under bash
    [ "${BASH_SOURCE-}" != "$0" ] && _cc_sourced=1
else
    case "${0##*/}" in cc.sh) _cc_sourced=0 ;; *) _cc_sourced=1 ;; esac
fi
if [ "$_cc_sourced" -eq 0 ]; then
    printf 'cc: this script must be SOURCED, not executed.\n' >&2
    printf '    Run:  . "%s"\n' "$0" >&2
    printf '    (or add that line to your ~/.zshrc / ~/.bashrc - see install.sh)\n' >&2
    exit 64
fi
unset _cc_sourced

CC_HOME="${CC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cc}"
CC_IDENTITIES="$CC_HOME/identities"
CC_DEFAULT="$CC_HOME/default"
# The shared store. Every identity symlinks its common dirs here.
CC_SHARED_ROOT="${CC_SHARED_ROOT:-$HOME/.claude}"
# Everything except auth is shared. Auth (.credentials.json, .claude.json,
# settings.json) stays per-identity - that is the whole point of switching.
CC_SHARED_DIRS="${CC_SHARED_DIRS:-projects skills agents commands}"

_cc_init() {
    [ -d "$CC_HOME" ] || mkdir -p "$CC_HOME"
    [ -f "$CC_IDENTITIES" ] || : > "$CC_IDENTITIES"
}

# Resolve id -> config dir. Empty output means "not registered".
_cc_dir() {
    _cc_init
    awk -v want="$1" '$1 == want { $1 = ""; sub(/^ /, ""); print; exit }' "$CC_IDENTITIES"
}

_cc_default_id() {
    _cc_init
    if [ -s "$CC_DEFAULT" ]; then
        head -n1 "$CC_DEFAULT"
    else
        # fall back to the first registered identity
        awk 'NF { print $1; exit }' "$CC_IDENTITIES"
    fi
}

_cc_known_ids() { _cc_init; awk 'NF { print $1 }' "$CC_IDENTITIES"; }

# --- shared-store linking ----------------------------------------------------
# Link each shared dir into the identity. If the identity already has a REAL
# directory there, merge it into the shared store first - refusing on any
# filename collision rather than silently overwriting someone's work.
_cc_link_shared() {
    dir="$1"
    [ "$dir" = "$CC_SHARED_ROOT" ] && return 0   # the primary IS the store

    # Never create the store root itself. If it sits on a removable or network
    # volume that isn't mounted, creating it would fabricate an empty store on
    # the mountpoint and link every identity into it - which looks exactly like
    # the tool ate your history, and shadows the real store once remounted.
    if [ ! -d "$CC_SHARED_ROOT" ]; then
        printf 'cc: shared store %s does not exist.\n' "$CC_SHARED_ROOT" >&2
        printf '    If it lives on a removable or network volume, mount it and retry.\n' >&2
        printf '    To create it deliberately: mkdir -p "%s"\n' "$CC_SHARED_ROOT" >&2
        return 1
    fi

    # zsh does NOT word-split unquoted expansions (no SH_WORD_SPLIT by default),
    # so `for sub in $CC_SHARED_DIRS` would iterate ONCE over the whole string
    # on macOS's default shell. eval+set re-parses as command words, which
    # splits identically in every shell.
    eval "set -- $CC_SHARED_DIRS"
    for sub in "$@"; do
        target="$CC_SHARED_ROOT/$sub"
        link="$dir/$sub"
        [ -d "$target" ] || mkdir -p "$target"

        if [ -L "$link" ]; then
            continue                              # already linked
        elif [ ! -e "$link" ]; then
            ln -s "$target" "$link" 2>/dev/null
            # Some filesystems (and Git Bash without winsymlinks) silently COPY
            # the whole target instead of linking. Remove the copy before
            # erroring, or the next run sees a real dir full of the store's
            # files and wedges on "collision" forever.
            if [ ! -L "$link" ]; then
                [ -e "$link" ] && rm -rf "$link"
                printf 'cc: could not create a symlink at %s\n' "$link" >&2
                printf '    this filesystem does not appear to support symlinks.\n' >&2
                printf '    On Git Bash, use PowerShell (install.ps1) instead, or set\n' >&2
                printf '    MSYS=winsymlinks:nativestrict before starting the shell.\n' >&2
                return 1
            fi
        elif [ -d "$link" ]; then
            # Real directory with content: merge, but never clobber.
            collisions=$(cd "$link" && find . -mindepth 1 -maxdepth 1 -exec sh -c \
                '[ -e "$1/$(basename "$2")" ] && basename "$2"' _ "$target" {} \; 2>/dev/null)
            if [ -n "$collisions" ]; then
                printf 'cc: refusing to merge %s - these already exist in the shared store:\n' "$link" >&2
                # quoted + sed, not `printf '  %s\n' $collisions`: unquoted
                # splitting would break a colliding name containing spaces
                # across several bullet lines.
                printf '%s\n' "$collisions" | sed 's/^/  /' >&2
                printf 'cc: resolve by hand, then re-run.\n' >&2
                return 1
            fi
            if ! cp -R "$link/." "$target/" 2>/dev/null; then
                printf 'cc: merge of %s failed; leaving it untouched.\n' "$link" >&2
                return 1
            fi
            bak="$link.premerge-$(date +%Y%m%d%H%M%S)"
            mv "$link" "$bak" || return 1
            ln -s "$target" "$link" 2>/dev/null
            # Verify here too: without this the user is told "merged" while
            # actually holding a divergent copy that never syncs.
            if [ ! -L "$link" ]; then
                [ -e "$link" ] && rm -rf "$link"
                mv "$bak" "$link"            # restore rather than leave a fake
                printf 'cc: could not create a symlink at %s - restored the original.\n' "$link" >&2
                printf '    this filesystem does not appear to support symlinks.\n' >&2
                return 1
            fi
            printf 'cc: merged %s into the shared store (backup: %s)\n' "$sub" "$(basename "$bak")"
        fi
    done
    return 0
}

# --- concurrent-session guard ------------------------------------------------
# Two Claude Code processes sharing one config dir can race on .claude.json and
# overwrite it with an empty stub, and the backup rotation then evicts the good
# copies. See anthropics/claude-code#78439. Only sessions started via `cc` are
# tracked - a bare `claude` bypasses this.
_cc_lockfile() { printf '%s/.cc-session.lock' "$1"; }

_cc_check_lock() {
    lock=$(_cc_lockfile "$1")
    [ -f "$lock" ] || return 0
    pid=$(head -n1 "$lock" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) rm -f "$lock"; return 0 ;; esac
    if kill -0 "$pid" 2>/dev/null; then
        printf 'cc: WARNING - another Claude Code session (pid %s) is already using\n' "$pid" >&2
        printf '    %s\n' "$1" >&2
        printf '    Concurrent sessions on one config dir can corrupt .claude.json\n' >&2
        printf '    (anthropics/claude-code#78439). Close it, or re-run with: cc -f %s\n' "$2" >&2
        return 1
    fi
    rm -f "$lock"                                  # stale lock, owner is gone
    return 0
}

# --- commands ----------------------------------------------------------------
ccnew() {
    _cc_init
    id="$1"; dir="$2"
    if [ -z "$id" ]; then
        printf 'usage: ccnew <id> [config-dir]\n' >&2; return 1
    fi
    # The registry is whitespace-delimited ("id dir" per line), so an id with a
    # space silently corrupts it: the identity can never be looked up or removed
    # by its own name again.
    case "$id" in
        *[[:space:]]*)
            printf 'cc: identity name cannot contain whitespace\n' >&2; return 1 ;;
    esac
    if [ -n "$(_cc_dir "$id")" ]; then
        printf 'cc: identity [%s] already exists\n' "$id" >&2; return 1
    fi
    [ -n "$dir" ] || dir="$HOME/.claude-$id"
    case "$dir" in "~"*) dir="$HOME${dir#\~}" ;; esac
    # Two identities pointing at one config dir defeat the session guard (both
    # think they own it) and ccrm on either strips the other's links.
    existing=$(awk -v d="$dir" '{ p=$0; sub(/^[^ ]+[ ]/,"",p); if (p == d) { print $1; exit } }' "$CC_IDENTITIES")
    if [ -n "$existing" ]; then
        printf 'cc: %s is already registered to [%s].\n' "$dir" "$existing" >&2
        printf '    Two identities must not share a config directory.\n' >&2
        return 1
    fi
    mkdir -p "$dir" || return 1
    printf '%s %s\n' "$id" "$dir" >> "$CC_IDENTITIES"
    printf 'cc: registered [%s] -> %s\n' "$id" "$dir"
    printf "    run 'cc %s' and log in.\n" "$id"
}

ccrm() {
    _cc_init
    id="$1"
    dir=$(_cc_dir "$id")
    if [ -z "$dir" ]; then printf 'cc: no such identity [%s]\n' "$id" >&2; return 1; fi

    # Unlink the shared dirs FIRST. Deleting a symlink with `rm -r` would be
    # fine, but a user reaching for `rm -rf $dir` later would follow the links
    # and destroy the shared store, so we always leave the dir link-free.
    eval "set -- $CC_SHARED_DIRS"          # see _cc_link_shared: zsh won't split
    for sub in "$@"; do
        [ -L "$dir/$sub" ] && rm -f "$dir/$sub"
    done
    # Filter with awk on an exact STRING match, not a grep regex: an id
    # containing regex metacharacters (e.g. "a.b") would otherwise also match
    # and silently delete unrelated identities (e.g. "axb"). awk also lets an
    # empty result be a legitimate success - grep -v exits 1 when it filters
    # every line, which previously skipped the write entirely.
    awk -v want="$id" '$1 != want' "$CC_IDENTITIES" > "$CC_IDENTITIES.tmp" || true
    mv "$CC_IDENTITIES.tmp" "$CC_IDENTITIES"
    [ "$(_cc_default_id)" = "$id" ] && : > "$CC_DEFAULT"
    printf 'cc: unregistered [%s]. Its config dir is left in place:\n' "$id"
    printf '    %s\n' "$dir"
    if [ "${dir%/}" = "${CC_SHARED_ROOT%/}" ]; then
        # For the primary, those dirs are the store itself - nothing was
        # unlinked, and deleting it would destroy every identity's history.
        printf 'cc: WARNING - this directory IS the shared store.\n' >&2
        printf '    DO NOT DELETE IT. It holds the %s\n' "$CC_SHARED_DIRS" >&2
        printf '    of every other identity. Move the store first if you need it gone.\n' >&2
    else
        printf '    Shared dirs were unlinked, so deleting it is now safe.\n'
    fi
}

ccuse() {
    _cc_init
    id="$1"
    if [ -z "$id" ]; then printf 'usage: ccuse <id>\n' >&2; return 1; fi
    dir=$(_cc_dir "$id")
    if [ -z "$dir" ]; then
        printf 'cc: no such identity [%s]. Known: %s\n' "$id" "$(_cc_known_ids | tr '\n' ' ')" >&2
        printf "    create it with: ccnew %s\n" "$id" >&2
        return 1
    fi
    [ -f "$dir/.credentials.json" ] ||
        printf 'cc: note - [%s] has no credentials yet; you will be asked to log in.\n' "$id"
    printf '%s\n' "$id" > "$CC_DEFAULT"
    # Exported here so THIS shell updates too, not just new ones.
    CLAUDE_CONFIG_DIR="$dir"; export CLAUDE_CONFIG_DIR
    printf 'cc: default identity -> [%s]\n' "$id"
    printf '    config: %s\n' "$dir"
    printf '    this shell and all new ones: bare `claude` is now [%s].\n' "$id"
    printf '    already-open shells keep their old identity until restarted.\n'
}

ccwho() {
    _cc_init
    def=$(_cc_default_id)
    printf 'default: [%s]\n' "${def:-<none>}"
    printf 'this shell: %s\n\n' "${CLAUDE_CONFIG_DIR:-<unset>}"
    if [ ! -s "$CC_IDENTITIES" ]; then
        printf 'no identities registered yet - start with: ccnew <id>\n'; return 0
    fi
    while read -r id dir; do
        [ -n "$id" ] || continue
        mark=' '; [ "$id" = "$def" ] && mark='*'
        state='-'
        [ -f "$dir/.credentials.json" ] && state='logged in'
        live=''
        lock=$(_cc_lockfile "$dir")
        if [ -f "$lock" ]; then
            pid=$(head -n1 "$lock" 2>/dev/null)
            case "$pid" in ''|*[!0-9]*) : ;; *) kill -0 "$pid" 2>/dev/null && live=' (session running)' ;; esac
        fi
        printf '%s %-12s %-11s %s%s\n' "$mark" "$id" "$state" "$dir" "$live"
    done < "$CC_IDENTITIES"
}

cc() {
    _cc_init
    force=0
    if [ "$1" = "-f" ] || [ "$1" = "--force" ]; then force=1; shift; fi

    id="$1"
    if [ -n "$id" ] && [ -n "$(_cc_dir "$id")" ]; then
        shift
    elif [ -n "$id" ] && [ "${id#-}" = "$id" ]; then
        # A bare word that is not a known identity: almost always a typo.
        # Never auto-create - that silently makes an empty, logged-out account.
        printf 'cc: unknown identity [%s]. Known: %s\n' "$id" "$(_cc_known_ids | tr '\n' ' ')" >&2
        printf "    if you meant to create it: ccnew %s\n" "$id" >&2
        return 1
    else
        id=$(_cc_default_id)                       # no id given -> use default
    fi

    if [ -z "$id" ]; then
        printf 'cc: no identities registered - start with: ccnew <id>\n' >&2; return 1
    fi
    dir=$(_cc_dir "$id")
    [ -d "$dir" ] || mkdir -p "$dir"

    # Check the lock BEFORE touching the filesystem: a run we are about to
    # refuse should not have merged or linked anything first.
    if [ "$force" -eq 0 ]; then
        _cc_check_lock "$dir" "$id" || return 1
    fi
    _cc_link_shared "$dir" || return 1

    lock=$(_cc_lockfile "$dir")
    printf '%s\n' "$$" > "$lock"
    # Drop the lock however we exit, including Ctrl-C. Single quotes are
    # deliberate: $lock must be expanded when the trap fires, not now.
    # shellcheck disable=SC2016
    trap 'rm -f "$lock"' INT TERM

    printf 'cc: claude as [%s]  (config: %s)\n' "$id" "$dir"
    CLAUDE_CONFIG_DIR="$dir" claude "$@"
    # NOT `status`: that is a READ-ONLY special parameter in zsh. Assigning it
    # aborts the function, so the lock below would never be removed and the
    # next launch would see this shell's own PID and refuse forever.
    _cc_status=$?

    rm -f "$lock"
    trap - INT TERM
    return $_cc_status
}

# On shell startup, adopt the saved default so bare `claude` matches `cc`.
if [ -z "$CLAUDE_CONFIG_DIR" ]; then
    _cc_boot_id=$(_cc_default_id 2>/dev/null)
    if [ -n "$_cc_boot_id" ]; then
        _cc_boot_dir=$(_cc_dir "$_cc_boot_id" 2>/dev/null)
        [ -n "$_cc_boot_dir" ] && { CLAUDE_CONFIG_DIR="$_cc_boot_dir"; export CLAUDE_CONFIG_DIR; }
    fi
    unset _cc_boot_id _cc_boot_dir
fi
