# MILTON.md

Milton fork of [digimata/parrot](https://github.com/digimata/parrot). Unreviewed upstream
base at `86ab0a78ab042725fc9835281709d9b47e174ad0` (tag `v0.0.5`; upstream head
`62f8d98a41422d55af21bfe337ec588dd7d2da46` at import, 2026-08-26); reviewed deltas since.

The import carries three upstream commits past `v0.0.5` — two documentation/licence commits
and one four-line change to `Sources/parrot/UI/MenuBarController.swift`. Those are part of the
unreviewed base, not a reviewed delta.

## Behaviour

A hold is cancelled by any keystroke, click or scroll, so a hotkey chord reaches the
application instead of dictating; modifier-only presses (Shift, Command, Control, the other
Option key) deliberately do not cancel, because holding one to capitalise or to reach a
punctuation mark is part of speaking a sentence, not an attempt to use the hotkey as a chord.

The default hotkeys are `fn,right-option`, which suits a US layout. On an AltGr layout —
German, Swiss, French, the Nordic layouts — right Option is the key that types `@ [ ] { } | \ ~`,
so on those keyboards every one of those characters would start and stop the audio engine and
flash the overlay. The fix on those keyboards is `--hotkey fn`. A hand-run daemon takes it on the
command line; on the fleet, the Milton bootstrap writes `--hotkey <value>` into the LaunchAgent's
`ProgramArguments` from its own `PARROT_HOTKEY` constant, which `MILTON_PARROT_HOTKEY` overrides at
bootstrap time. The binary reads no environment variable of its own, so setting one in the running
daemon's environment changes nothing.

Downloaded models live under `~/Library/Application Support/parrot`: WhisperKit lays out the
model at `models/argmaxinc/whisperkit-coreml/<variant>` and its tokenizer at
`models/<tokenizer repo>` (for example `models/openai/whisper-large-v3`), so the whole `models/`
tree is the store. Upstream leaves WhisperKit's default, `~/Documents/huggingface`, which macOS
guards behind a Files & Folders prompt for whatever process touches it and iCloud may sync or
evict. `--model-dir <path>` on `run` and `models download` overrides the location; there is no
fallback to the old path, so a store downloaded by an older build has to be moved, which on the
fleet the Milton bootstrap does once, `models/` as a whole. The daemon never downloads: before
loading, `run` checks the four CoreML pieces and the tokenizer are on disk; a store it has proven
missing or torn is reported on one line starting `parrot stopped:` and, under launchd, exits 0 so
the KeepAlive agent stays stopped instead of respawning every ten seconds (1 at a terminal). Any
other load failure exits 1 and respawns, since it may be transient. Only `models download`
fetches, and a stopped agent does not notice a download or a moved store on its own: after
either, `launchctl kickstart -k gui/$(id -u)/com.digimata.parrot`, which the Milton bootstrap does
as part of its reload. The fleet
LaunchAgent carries no `--model-dir`; the location is the binary's default, and the bootstrap
writes no such flag.

Injected text is trimmed of leading and trailing whitespace. Two dictations in a row therefore run
together unless the first ends in punctuation, which is where the sentence spacing comes from.
Unicode tag characters are dropped, so a subdivision flag — the Scottish, Welsh and English ones —
arrives as the plain black flag it is built from.

When the Accessibility grant is missing the daemon opens the system prompt and exits 0, and
launchd deliberately does not relaunch it (a non-zero exit would relaunch every ten seconds and
reload the model each time). After granting access, bring it back by hand:
`launchctl kickstart -k gui/$(id -u)/com.digimata.parrot`, or re-run the Mac setup; nothing
happens on its own until the next login.

**Accepted risk.** A key pressed and released entirely inside the interval between the hotkey going
down and the hold starting is seen by neither the chord tap, which is not listening yet, nor the
key-state scan, which reads a key that is already back up: that hold records instead of cancelling.
Closing it needs an always-on observer of every keystroke, which this fork deliberately does not
run — that is an Accessibility-privileged process reading everything typed, password fields
included, to catch a window a few milliseconds wide.

## Release

Tag `v0.0.5-milton.N` on `main` triggers `.github/workflows/release.yml`. The release control
is the tag ruleset: only an organisation admin can create, move or delete a `v*` tag, and
creating the tag is the approval. The `release` environment carries a tag-pattern deployment
policy only; required reviewers on a private-repo environment need GitHub Enterprise, which this
organisation does not have, so there is no approval pause and none is claimed. The job builds `parrot-macos-arm64.tar.gz`,
mints an `actions/attest-build-provenance` attestation, verifies that attestation against this
repo, this workflow and the tag before publishing, and attaches the tarball, its `.sha256`
sidecar and the Sigstore bundle to the release.

The binary is unsigned. The trust story is the per-user TCC grants plus the digest pin in
Milton-Group/infra. See `docs/onboarding-guide/mac-setup/README.md` there for the bump and
verification procedure.

## Upstream

`upstream` remote is https://github.com/digimata/parrot. A GitHub fork of a public repo cannot
be private, so this repository is an independent private repo carrying upstream history rather
than a fork object; `main` was imported from upstream's `master` with history intact.
