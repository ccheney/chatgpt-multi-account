# ChatGPT Multi-Account Desktop Launcher

Run additional ChatGPT Desktop windows on macOS with separate OAuth accounts.
The launcher supports the current ChatGPT app, which replaced the Codex app,
as well as legacy `Codex.app` installations.

This is an unsupported local workaround. By default it creates a clean isolated
Codex home and Chromium profile for the extra account. It does not symlink or
share history unless you explicitly opt in.

The renamed app still uses Codex internals such as `~/.codex`, the bundled
`codex` CLI, and `~/Library/Application Support/Codex`. The secondary directory
names below intentionally retain `Codex` so existing accounts keep working.

## Quick Start

```bash
chmod +x ./codex-multi-account.sh
./codex-multi-account.sh
```

The default secondary account uses:

- `~/.codex-multi-2`
- `~/Library/Application Support/Codex-Multi-2`

After the new ChatGPT window opens, sign in with your second account.

The script auto-detects `/Applications/ChatGPT.app` first and falls back to a
legacy `/Applications/Codex.app`. It reads the bundle's executable name, so both
the current `ChatGPT` executable and the former `Codex` executable are supported.
To use an app in a different location:

```bash
./codex-multi-account.sh --app "/path/to/ChatGPT.app"
```

You can also set `CHATGPT_APP`. The legacy `--codex-app` option and `CODEX_APP`
environment variable remain available for backward compatibility.

## More Accounts

Launch N total accounts, counting your normal ChatGPT app as account 1:

```bash
./codex-multi-account.sh --accounts 5
```

That launches `multi-2` through `multi-5`.

For a named secondary account:

```bash
./codex-multi-account.sh --account work
```

That uses `~/.codex-work` and `~/Library/Application Support/Codex-work`.

## Optional Shared History

By default, every account has separate projects, chats, runtime data, and auth.

To share project/sidebar/chat history from your primary `~/.codex` profile:

```bash
./codex-multi-account.sh --symlink-history
```

Auth stays separate. The script automatically detects the current
`state_*.sqlite` file, so rerunning it can relink after Codex changes suffixes
such as `state_5.sqlite` to `state_6.sqlite`.

Quit ChatGPT/Codex windows before changing shared-history links.

## Reset

Remove all managed secondary Codex homes and profiles created by this script:

```bash
./codex-multi-account.sh --reset
```

Remove a specific account or account range:

```bash
./codex-multi-account.sh --reset --account work
./codex-multi-account.sh --reset --accounts 5
```

Reset refuses to remove your primary `~/.codex`, your home directory, or the
normal ChatGPT/Codex app profile. Quit matching secondary windows before reset.
