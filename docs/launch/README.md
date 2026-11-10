# Launch drafts

Drafts for public posts. Nothing in this folder has been posted or submitted. Read each one,
edit it into your own voice, and check the claims against `docs/GUIDE.md` first. Claims must
stay honest: Android only, Linux/macOS hosts, notifications off by default, Claude Code
approvals checked on a computer and not yet on a phone.

Why this exists: a new page on a shared domain ranks mostly on links, so the work now is
links and listings, not more on-page tweaks (see the SEO notes in the session history and
`site/`).

## 1. dev.to post

`devto-approve-claude-code-from-android.md`. It is set to `published: false` and its
`canonical_url` points at the guide on the site, so the site stays the original. dev.to pages
already rank for "approve claude code from phone", so this is the highest-value post.

## 2. Awesome lists (pull requests)

Checked on 2026-11-10 with `gh search repos`:

| List | Stars | Notes |
| --- | --- | --- |
| [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) | about 57,700 | Active. Has a `CONTRIBUTING.md`: read it first, it may ask for a specific submission route. |

The other "awesome ai coding agents" lists found have fewer than 10 stars, so they are not worth
the effort yet. Entry text, to adapt to the list's format:

> **herdr mobile**: free, open-source Android app that shows every coding agent on every
> computer, shows the exact command, and lets you approve it from your phone over SSH. No
> relay, no account. Works with Claude Code, Codex and omp through herdr.
> https://github.com/tuan3w/herdr-mobile

## 3. herdr.dev

Competitors already advertise herdr support, so ask herdr's maintainers for a mention on an
integrations or ecosystem page. Message to adapt:

> Hi, I built herdr mobile, a free open-source Android client for herdr over direct SSH (no
> relay, no account): board of all agents, read-the-command approvals, live terminal, worktrees.
> It uses herdr's API socket (and `herdr remote-api-bridge` on 0.9+). Would you be open to
> listing it on an integrations or community page? https://tuan3w.github.io/herdr-mobile/

## 4. Show HN

Title: `Show HN: herdr mobile, approve your coding agents from an Android phone (open source)`

Body (short, honest, first comment explains the limits):

> I run several coding agents on several machines and kept missing the moment one asked for
> permission. herdr mobile shows every agent in one list, shows the exact command, and lets
> you answer from an Android phone over direct SSH. Risky answers (push, delete, always allow)
> need a hold, nothing is approved on a timeout, and the app re-reads the question before it
> sends. There is no relay and no account. Limits: Android only, Linux/macOS hosts, Claude Code
> approvals are checked on a desktop and not yet on a phone, notifications are off by default.
> Demo you can try in the browser: https://tuan3w.github.io/herdr-mobile/#try

## 5. Reddit and forums

Read each community's self-promotion rules before posting, and post as a person, not an ad. The
dev.to post text works as the body. Do not post the same text in several places on the same day.

## 6. F-Droid and other stores

Open-source Android apps can be listed on F-Droid, which brings a strong backlink and an install
path without Play. Whether a Flutter build passes F-Droid's reproducible-build checks has not
been checked. That is a separate task.
