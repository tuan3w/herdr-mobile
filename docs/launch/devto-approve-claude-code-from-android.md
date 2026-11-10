---
title: Approve Claude Code from an Android phone, over SSH, with no relay
published: false
description: Read the exact command Claude Code asks about and approve it from an Android phone. Direct SSH or Tailscale, no relay, no account.
tags: claudecode, android, ai, opensource
canonical_url: https://tuan3w.github.io/herdr-mobile/guides/approve-claude-code-from-android/
cover_image: https://tuan3w.github.io/herdr-mobile/img/og.jpg
---

<!--
DRAFT for the owner to read, edit and post. Nothing here has been published.
Before posting: re-check every claim against docs/GUIDE.md, keep the limits section, and
keep canonical_url so the guide on the site stays the original.
-->

Claude Code stops and asks before it runs a command. When I am away from my desk, it just waits. I wanted to see who is waiting, read the exact command, and answer from my phone, without sending my commands through someone else's server.

So I built herdr mobile, a free, open-source Android app. This is how it works and what it does not do yet.

## What it is

The app reads agents from [herdr](https://herdr.dev), a terminal workspace for coding agents. It connects to each of your computers directly over SSH (a key, a password or Tailscale SSH). There is no relay, no public port and no account.

![The Agents list on a phone: one agent needs you](https://tuan3w.github.io/herdr-mobile/img/board-light.webp)

## The approval rules

- You read the exact command before you answer.
- Harmless answers send on a tap.
- Risky answers, such as a push, a delete or "always allow", need a hold of about 0.7 seconds. A tap only shows why.
- Nothing is approved for you, by default or on a timeout.
- Just before sending, the app re-reads the question. If you already answered on your computer, nothing is sent.

You can try the hold in your browser on [the home page](https://tuan3w.github.io/herdr-mobile/#try).

## Set it up

1. Run `claude` in a herdr pane as usual.
2. Install the APK from the [latest release](https://github.com/tuan3w/herdr-mobile/releases/latest). Check it against `SHA256SUMS` if you like.
3. In the app: Machines, then +. Add the host, port and user, and pick Tailscale, a key or a password. The app can generate an Ed25519 key and copy a one-line `authorized_keys` command.
4. Tap Test connection. Then open the board.

The full walk-through, with the limits, is in [the guide](https://tuan3w.github.io/herdr-mobile/guides/approve-claude-code-from-android/).

## What it does not do yet

- Android only. Linux and macOS computers only.
- Claude Code approvals are verified through the app's own client on a computer, not yet on a phone. omp is the agent verified end to end on a phone. Codex chat works with approvals unverified, and pi is built with no verified turn.
- Notifications are off by default. Turning them on runs a small background service and costs battery. I have not measured how much.
- Answer buttons on notifications have not been tested on a real phone.

## Other ways to do this

Remote Control from Anthropic, a hook with ntfy, an SSH terminal app and hosted apps all work for some people. I compared them [here](https://tuan3w.github.io/herdr-mobile/guides/ways-to-approve-claude-code-from-your-phone/), and I would like corrections if I got one wrong.

Source and releases: https://github.com/tuan3w/herdr-mobile (GPL-3.0).
