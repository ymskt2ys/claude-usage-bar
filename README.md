# ClaudeUsageBar

**English** · [日本語](README.ja.md)

A macOS menu bar app that shows how much of your Claude plan you have used.

```
5h 14% · 7d 31% · F 3%
```

- `5h` — five-hour session limit
- `7d` — weekly limit across all models
- `F` — weekly limit scoped to a single model (currently Fable)

Click it for a bar and percentage per limit, the time until each one resets, and when the data
was fetched. Turns orange at 75% and red at 90%. Refreshes every 60 seconds.

## Requirements

- macOS 13 or later (Apple Silicon and Intel)
- Xcode Command Line Tools — `swiftc` is enough, the full Xcode app is not needed
- A Claude subscription. This shows plan utilization, so it has nothing to display for
  pay-as-you-go API key usage

Each limit has its own prerequisite.

| Limit | Needs |
|---|---|
| Five-hour, weekly (all models) | The **Claude desktop app**, which records utilization locally |
| Weekly (per model) | A **signed-in Claude Code CLI**, whose Keychain OAuth credentials are used to call the API |

With neither available, the app falls back to the cache in `~/.claude.json`, which is only
refreshed when the Claude Code CLI runs.

## Distribution

The built `.app` is ad-hoc signed (`codesign -s -`), so **Gatekeeper will block it if you download
it from somewhere**. Building it yourself avoids that, since a locally built app is never
quarantined. Shipping a downloadable build would require an Apple Developer Program membership
and notarization.

## When no numbers show up

```bash
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --diagnose
```

Prints which source each limit came from, and why the API call failed if it did.

## Build and run

```bash
./build.sh
cp -R build/ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

`build.sh` recreates `build/` from scratch every time, so keep the resident copy in `/Applications`.

No Xcode project involved: `swiftc` compiles the two source files directly and the script assembles
the `.app` around them, once per architecture, joined with `lipo`. `LSUIElement` is set, so no Dock
icon appears.

## Launch at login

Use the "ログイン時に起動" checkbox in the panel, which registers the app as a login item via
`SMAppService`. The command line works too.

```bash
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --enable-login-item
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --disable-login-item
```

Registration is tied to the `.app`'s path. After moving the app, run `--disable-login-item` at the
old path and `--enable-login-item` at the new one.

## Where the data comes from

Each limit has its own source. They are tried top to bottom, and the first one that answers wins.

| Limit | Source | Auth | Freshness |
|---|---|---|---|
| Five-hour, weekly (all) | `~/Library/Application Support/Claude/plan-usage-history.json` | none | written by the Claude desktop app every 15 minutes |
| Weekly (per model, e.g. Fable) | `GET https://api.anthropic.com/api/oauth/usage` | OAuth | on every refresh |
| Everything else failed | `cachedUsageUtilization` in `~/.claude.json` | none | only when the Claude Code CLI runs |

The per-model weekly limit is **not stored locally anywhere**, so without a working API call it
falls back to a cached value. Stale rows are annotated in the panel, e.g. "9/14 12:50 時点".

A cached value is worthless once that limit's reset time has passed — it is back to 0 by then. In
that case the app shows `—` instead of a number and says so, rather than quietly serving an old
figure.

### About the OAuth path

The access token is read from `claudeAiOauth.accessToken` in the Keychain item
`Claude Code-credentials`. When it has expired, the app refreshes it via
`POST https://platform.claude.com/v1/oauth/token` (`grant_type=refresh_token`) and **writes the
result back to the Keychain**. Refreshing without writing back would break Claude Code's own login
as soon as the refresh token rotates, so the two always happen together. Every other key in that
item, `mcpOAuth` included, is preserved untouched.

If the refresh token itself is rejected (`invalid_grant`), signing in to `claude` once in a terminal
restores it. The five-hour and weekly numbers keep working from local sources in the meantime.

This relies on endpoints that are not public API. They can change without notice.

## Layout

| File | Role |
|---|---|
| `Sources/Usage.swift` | Keychain access, API calls, cache reads, JSON parsing |
| `Sources/App.swift` | The `MenuBarExtra` UI and polling |
| `build.sh` | Builds the universal `.app` bundle and ad-hoc signs it |

The signing identifier is pinned in `build.sh` so that rebuilding does not trigger a new Keychain
access prompt every time.
