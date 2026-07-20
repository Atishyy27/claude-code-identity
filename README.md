# claude-code-identity

Run multiple Claude Code accounts on one machine — sharing your chat history, skills, agents and commands between them, while keeping logins separate.

Works on **macOS, Linux and Windows**.

```console
$ ccwho
default: [work]
this shell: /Users/me/.claude-work

  personal     logged in   /Users/me/.claude
* work         logged in   /Users/me/.claude-work  (session running)

$ ccuse personal
cc: default identity -> [personal]
    this shell and all new ones: bare `claude` is now [personal].
```

## Why this one

There are a lot of Claude Code account switchers. [`claude-swap`](https://github.com/realiti4/claude-swap) is the most mature and has a TUI, a menu bar app and rate-limit-aware auto-switching — if you just want to switch accounts, use that. This tool exists for two things it doesn't do:

**1. It refuses to let two sessions corrupt your config.**

Claude Code writes `~/.claude.json` non-atomically. Two processes on the same config directory can race, and one will overwrite a ~57 KB config with a ~50 byte stub — which looks exactly like being logged out (you're not; auth lives in a separate `.credentials.json`). Worse, the backup rotation keeps only five copies and counts the junk stubs, so a handful of bad launches silently evicts your last good backup.

This is one of the most repeatedly filed bugs against Claude Code — [#28824](https://github.com/anthropics/claude-code/issues/28824), [#28837](https://github.com/anthropics/claude-code/issues/28837), [#29143](https://github.com/anthropics/claude-code/issues/29143), [#40226](https://github.com/anthropics/claude-code/issues/40226), and [#78439](https://github.com/anthropics/claude-code/issues/78439) among others — and every other switcher sidesteps it by fully isolating each account. If you *want* accounts to share a store, that's not an option. So `cc` tracks a lock per config dir and stops you:

```console
$ cc work
cc: WARNING - another Claude Code session (pid 48213) is already using
    /Users/me/.claude-work
    Concurrent sessions on one config dir can corrupt .claude.json
    (anthropics/claude-code#78439). Close it, or re-run with: cc -f work
```

**2. It shares a real store, by symlink — not by copying.**

`projects/` (chat history *and* memories), `skills/`, `agents/` and `commands/` are symlinked (junctioned on Windows) into every identity from one shared directory. There's one copy on disk, so a session started under any identity can `/resume` any past conversation, and a skill you write as one account is instantly there for the others. Only auth — `.credentials.json`, `.claude.json`, `settings.json` — stays per-identity.

## Install

**macOS / Linux**

```sh
git clone https://github.com/Atishyy27/claude-code-identity.git
cd claude-code-identity && ./install.sh
```

Then restart your shell, or `. ~/.config/cc/cc.sh`.

**Windows (PowerShell)**

```powershell
git clone https://github.com/Atishyy27/claude-code-identity.git
cd claude-code-identity; .\install.ps1
```

Then restart PowerShell, or dot-source it: `. "$env:USERPROFILE\.config\cc\cc.ps1"`.

The installer copies the script and appends one line to your shell profile. It must be *sourced*, not executed — `ccuse` needs to export into your current shell.

## Use

```sh
ccnew personal ~/.claude   # register your existing account as the shared store
ccnew work                 # register a second, at ~/.claude-work
cc work                    # launch as work (first run: log in)
ccuse work                 # make work the default, so bare `claude` is work too
ccwho                      # who exists, who's logged in, what's running
cc work --resume           # extra args pass straight through to claude
ccrm work                  # unregister safely (unlinks first, see footgun below)
```

The first identity you register pointing at `~/.claude` becomes the shared store; everything else links into it.

## How it works

Claude Code reads the `CLAUDE_CONFIG_DIR` environment variable to decide which config directory — and therefore which logged-in account — to use. `ccuse` persists that variable, so plain `claude` picks it up with no wrapper involved.

**It's read once, at process launch.** A running session can never change account. To move a conversation to a different identity, run `cc <id> --resume` from the same directory and close the old window. Already-open terminals keep their old identity until restarted — nothing can reach into a running process's environment.

## Footguns

**Never `rm -rf` an identity directory by hand, and never `Remove-Item -Recurse` one on Windows.** Both follow the links and delete the *contents of your shared store* — every chat, memory and skill. Use `ccrm`, which removes the links first and leaves the directory safe to delete.

## Limits

- Only sessions launched through `cc` are lock-tracked. A bare `claude` bypasses the guard — that's the tradeoff for `ccuse` making plain `claude` work at all.
- Identity is per-process, so there's no mid-session switching. This is a Claude Code constraint, not something a wrapper can fix.
- Windows uses junctions, which need no admin rights. macOS/Linux use symlinks. Both need a filesystem that supports them; `cc` errors out clearly if yours doesn't rather than silently copying.

## License

MIT
