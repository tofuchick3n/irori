# AGENTS

irori: a lean, native macOS chat app where Claude Code, Codex, Grok, and Muse brainstorm with the user in one thread (a "roundtable"). Tasks and artifacts live in Takibi (takibibase.com); irori is only the chat. The SwiftPM target and executable stay `Desk`; only the product brand is irori.

## Principles

- **Desk owns no capabilities.** Tools come from each agent CLI's own config (MCP servers, skills, the `takibi` CLI). Desk supervises agent processes, stores transcripts, and renders them. If a feature needs Desk to know about Takibi, Drive, or any provider, it is the wrong feature.
- **One agent speaks at a time.** Never run agents in parallel.
- **Stock SwiftUI first.** Native components, system colors, SF Symbols. No custom design system, no hex colors, no hand-drawn chrome. The only third-party dependencies are [Sparkle](https://sparkle-project.org) for updates and the Whistle speech model with its prebuilt Needle engine for voice input (`Vendor/Needle`, fetched by `scripts/fetch-whistle`). Replies render with Foundation's markdown parser into native text views (`MarkdownRenderer`, `MarkdownText`); a SwiftUI markdown view re-ran layout on every scroll step.
- **Approvals in the thread.** Reads never ask. Anything else an agent wants asks in the thread: once, in this thread, always, or no. Grok and Muse still auto-approve inside their sandboxes.

## Stack

- Swift 6 (strict concurrency), SwiftPM package, macOS 26+ deployment target, no Xcode project.
- `@Observable` models, `async`/`await`, `AsyncThrowingStream` for agent output.
- Swift Testing (`import Testing`) for tests.

## Commands

SwiftPM's own manifest sandbox fails inside an already-sandboxed process, so always pass `--disable-sandbox`:

```sh
scripts/fetch-whistle # once per clone: libneedle.a and whistle.cact into .build/whistle; the link needs it
swift build --disable-sandbox
swift test --disable-sandbox
swift run --disable-sandbox Desk
scripts/make-app      # build/<APP_NAME>.app, ad-hoc signed (name in scripts/brand.env)
scripts/install-app   # Developer ID signed, installed to /Applications
```

## Rules for agents working here

- Write only inside this repository. Tests must use temporary directories, never `~/Library/Application Support`.
- Do not commit; the reviewer commits after checking your work.
- Keep files small and named for what they hold. Match the surrounding code; no comments that restate the code.
- When `docs/PLAN.md` exists, it holds the milestones; build only the milestone you were asked for.
