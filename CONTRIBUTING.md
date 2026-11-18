# Contributing to Earshot

Thanks for helping. Bug reports, fixes, docs and new features are all welcome. This page explains how changes get in.

## How the project is run

Earshot has one maintainer ([@bradwasf](https://github.com/bradwasf)), who reviews and merges every pull request. Only the maintainer can push to this repository. Everyone else contributes from a fork. The maintainer decides what is merged and may close changes that don't fit the project's direction. Two things are fixed: Earshot stays fully local (no cloud APIs, and nothing leaves the Mac unless the user chooses an export), and it stays a single native macOS app.

For anything larger than a small fix, **open an issue first** and describe what you want to change, so you don't spend time on something that won't be merged.

## Reporting bugs

Use the **Bug report** issue form. Include your Mac model, macOS version, Earshot version, and the relevant part of `~/Library/Logs/Earshot/earshot.log`. The log never contains transcript text, but read it before you post it.

**Never attach transcripts, summaries or recordings of real calls.** They contain other people's words. Reproduce the problem with `scripts/make-test-call.py` or your own voice instead.

Security problems go through private reporting, not issues. See [SECURITY.md](SECURITY.md).

## Development setup

You need an Apple Silicon Mac with macOS 14.4 or newer and Xcode (Swift 5.10+). See the README for details.

```bash
git clone https://github.com/<you>/earshot.git
cd earshot
./setup.sh                 # Ollama + summary model, builds build/Earshot.app, downloads speech models
swift test                 # unit tests (no models, Ollama or audio hardware needed)
open build/Earshot.app
```

`scripts/build-app.sh` rebuilds just the app. `earshot-cli simulate` feeds audio files through the live pipeline, so you can test transcription without a real call (see "Command line" in the README).

## Making a change

1. Fork the repository and create a branch from **`dev`** (not `prod`).
2. Keep each pull request to one change. Small pull requests are reviewed faster.
3. Follow the existing style: Swift API naming, no new dependencies without discussing them in an issue first, and UI colours and type from `Sources/Earshot/Theme.swift` rather than stock controls.
4. Add or update tests in `Tests/EarshotCoreTests` for logic in `EarshotCore`, and make sure `swift test` passes.
5. If you change capture, transcription or the UI, try it in the real app and say how in the pull request.
6. Update `README.md` or `SETUP.md` when behaviour changes.
7. Open the pull request against `dev` and fill in the template. CI runs `swift build` and `swift test`. For first-time contributors it starts once the maintainer approves the run.

## Commits and licensing

- Write commit messages in the imperative ("Add …", "Fix …"), with a short subject line.
- By submitting a pull request you agree that your contribution is licensed under the project's [MIT License](LICENSE).
- Don't commit models, audio, build output or personal data. `.gitignore` covers the usual paths.

## Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). Be kind, and assume good intent.
