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
