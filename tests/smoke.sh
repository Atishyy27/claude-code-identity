#!/usr/bin/env sh
# Sandboxed smoke tests for cc.sh. Run under every shell we claim to support:
#     sh tests/smoke.sh   /   bash tests/smoke.sh   /   zsh tests/smoke.sh
#
# Everything runs against a temp HOME/CC_HOME/CC_SHARED_ROOT with a stubbed
# `claude`, so this can never touch a real config.

FAIL=0
ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAIL=1; }
chk()  { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got '$1', want '$2')"; fi; }

SRC=$(cd "$(dirname "$0")/.." && pwd)/cc.sh
T=$(mktemp -d)
export CC_HOME="$T/cfg" CC_SHARED_ROOT="$T/shared" HOME="$T/home"
mkdir -p "$HOME" "$CC_SHARED_ROOT" "$T/bin"
printf '#!/bin/sh\nprintf "STUB:%%s\\n" "$*"\n' > "$T/bin/claude"
chmod +x "$T/bin/claude"
PATH="$T/bin:$PATH"; export PATH

# Does this filesystem actually support symlinks? Git Bash on Windows silently
# copies instead, and cc correctly refuses there - so the link-dependent tests
# are not applicable rather than failing.
ln -s "$CC_SHARED_ROOT" "$T/.linkprobe" 2>/dev/null
if [ -L "$T/.linkprobe" ]; then SYMLINKS=1; else SYMLINKS=0; fi
rm -rf "$T/.linkprobe"

# shellcheck source=/dev/null
. "$SRC"

if [ "$SYMLINKS" -eq 1 ]; then
    # --- shared dirs must all link (regression: zsh does not word-split) ----
    ccnew work >/dev/null
    cc work >/dev/null 2>&1
    n=0
    for s in projects skills agents commands; do [ -L "$HOME/.claude-work/$s" ] && n=$((n + 1)); done
    chk "$n" "4" "all four shared dirs are symlinks"

    # --- launching twice must work (regression: zsh read-only $status) ------
    cc work >/dev/null 2>&1
    if cc work >/dev/null 2>&1; then ok "second launch is not blocked by a stale lock"
    else fail "second launch blocked - lock was not released"; fi

    # --- args pass through untouched ---------------------------------------
    out=$(cc work --resume -p "hi there" 2>/dev/null | grep '^STUB:')
    chk "$out" "STUB:--resume -p hi there" "claude args pass through verbatim"
else
    printf 'skip - symlink tests (this filesystem does not support symlinks)\n'
    ccnew work >/dev/null
fi

# --- unknown identity must be refused, not silently created -----------------
cc definitely-not-registered >/dev/null 2>&1
chk "$?" "1" "unknown identity is rejected"
if [ -d "$HOME/.claude-definitely-not-registered" ]; then
    fail "typo created a phantom identity dir"
else ok "typo did not create a phantom identity dir"; fi

# --- whitespace in an id corrupts the registry, so reject it ----------------
ccnew "bad id" >/dev/null 2>&1
chk "$?" "1" "identity name with whitespace is rejected"

# --- duplicate config dir must be rejected ----------------------------------
ccnew dup1 "$T/samedir" >/dev/null 2>&1
ccnew dup2 "$T/samedir" >/dev/null 2>&1
chk "$?" "1" "second identity on the same dir is rejected"

# --- ccrm must not regex-match unrelated ids --------------------------------
ccnew "a.b" "$T/ab" >/dev/null 2>&1
ccnew "axb" "$T/axb" >/dev/null 2>&1
ccrm "a.b" >/dev/null 2>&1
if awk '{print $1}' "$CC_HOME/identities" | grep -qx "axb"; then
    ok "ccrm did not collaterally remove a regex-similar id"
else fail "ccrm removed unrelated identity axb"; fi

# --- ccrm must actually deregister the LAST identity ------------------------
CC_HOME2="$T/cfg2"; (
    export CC_HOME="$CC_HOME2"
    # shellcheck source=/dev/null
    . "$SRC"
    ccnew solo "$T/solo" >/dev/null 2>&1
    ccrm solo >/dev/null 2>&1
    if [ -s "$CC_HOME2/identities" ]; then exit 1; else exit 0; fi
)
chk "$?" "0" "ccrm deregisters the last remaining identity"

# --- merge must refuse on collision rather than overwrite -------------------
ccnew coll "$T/coll" >/dev/null 2>&1
mkdir -p "$T/coll/skills" "$CC_SHARED_ROOT/skills"
echo LOCAL > "$T/coll/skills/dup.md"
echo SHARED > "$CC_SHARED_ROOT/skills/dup.md"
cc coll >/dev/null 2>&1
chk "$(cat "$CC_SHARED_ROOT/skills/dup.md")" "SHARED" "collision refused; shared copy survived"

# --- executing (not sourcing) must fail loudly ------------------------------
sh "$SRC" >/dev/null 2>&1
chk "$?" "64" "executing instead of sourcing exits 64"

rm -rf "$T"
[ "$FAIL" -eq 0 ] && printf '\nall tests passed\n' || printf '\nTESTS FAILED\n'
exit "$FAIL"
