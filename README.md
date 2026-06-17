# Sift

Sift is a macOS menu-bar app that turns your Slack activity into a tidy todo list.

It watches for the things that are genuinely yours to act on — questions aimed at you, threads you're part of, commitments you've made — and keeps them in a simple list on your Mac, each with a short AI-written summary. As the conversations move on, the list keeps itself current: items close out when something's handled and fade to "stale" when they go quiet.

Everything runs on your machine. Sift only ever **reads** Slack — it never posts, replies, or changes anything — and your data isn't stored in any cloud.

## How it works

- On a schedule (every 30 minutes by default), Sift reads your Slack: your mentions, DMs, threads you're in, and any channels you choose to watch.
- An AI model decides whether each thread is a real action for *you* and writes a one-line summary.
- The result shows up in the menu-bar list — prioritised, grouped by date, and updated on each run. Related threads about the same piece of work get merged into one item.

## What you need

- **macOS 14 or later.**
- **Slack access** — connect in one click, or use your own token (see below).
- **An AI provider key** — Anthropic, OpenAI, Google Gemini, Groq, or DeepSeek. You bring your own key; it's stored in your macOS Keychain and called directly from your Mac.

## Build and run

```bash
./scripts/build-app.sh        # builds ./Sift.app
open ./Sift.app
```

A local build isn't code-signed, so the first time you open it macOS may warn — right-click the app and choose **Open** to get past that once.

First launch walks you through connecting an AI provider and Slack.

## Connecting an AI provider

Pick any supported provider and paste its API key. Sift uses two tiers — a **fast** model for quick triage and a more **capable** model for writing summaries — and you choose the provider and model for each in Settings. Keys stay in your Keychain and are sent only to the provider you picked.

## Connecting Slack

There are two ways, depending on how much you want to set up yourself.

### Option A — Connect Slack (one click)

In onboarding, click **Connect Slack**. Your browser opens Slack's authorisation page; approve it and you're sent back to Sift with access in place. Nothing to create or configure.

### Option B — Use your own Slack token

If you'd rather run entirely on your own infrastructure, create a Slack app in your workspace and connect Sift with its user token:

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**, and pick your workspace.
2. Under **OAuth & Permissions**, add these **User Token Scopes** (all read-only):

   `search:read`, `channels:read`, `channels:history`, `groups:read`, `groups:history`, `im:read`, `im:history`, `mpim:read`, `mpim:history`, `users:read`, `users:read.email`

3. Install the app to your workspace, then copy the **User OAuth Token** (it starts with `xoxp-`).
4. In Sift, choose **Use your own token** and paste it in.

Sift keeps the token in your Keychain and uses it only to read Slack on your behalf.

## Watching extra channels

By default Sift tracks your mentions, DMs, and threads you're in. To also scan a specific channel — useful for a shared or customer channel you want covered even when you're not tagged — open **Settings → Integrations → Slack** and add it by name. The next sync picks it up.

## Where your data lives

- **Todos:** a local SQLite database at `~/Library/Application Support/Sift/Sift.sqlite`.
- **Credentials:** your AI key and Slack token live in the macOS Keychain.
- Sift talks to exactly two kinds of service — Slack (read-only) and the AI provider you chose. Nothing else, and nothing leaves your Mac beyond those calls.

To start fresh: quit Sift, delete the SQLite file, and relaunch. To disconnect everything, use **Settings → Danger Zone → Clear all credentials**.

## Project layout

```
Sources/Sift/   The app — SwiftUI + AppKit menu-bar UI, SwiftData models,
                the sync worker, and the provider/Slack clients.
scripts/        build-app.sh (build the .app) and deploy.sh (dev rebuild).
```

The one-click "Connect Slack" sign-in is backed by a small hosted Cloudflare Worker that isn't part of this repo. It only does the OAuth handoff — you don't need it to build or run Sift, and Option B (your own token) doesn't touch it at all.
