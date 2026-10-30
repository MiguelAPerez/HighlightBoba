# Contributing to HighlightBoba

> **Issues welcome, PRs not yet.** Until the grammar format is stable, pull requests
> from outside contributors are closed without review. Bug reports, language requests
> and design feedback are very welcome as issues. This guide describes how PRs will
> work once they open, and the rules maintainers already follow.

## Two lanes

Every PR belongs to exactly one lane. Say which in the PR description.

### Data lane: grammars, fixtures and queries

Files under `Sources/HighlightBoba/Grammars/` and `Tests/HighlightBobaTests/Fixtures/`.

- A grammar change ships with fixtures that cover it. See [docs/GRAMMAR.md](docs/GRAMMAR.md#fixtures).
- A bug fix includes a fixture that fails without the fix.
- `HIGHLIGHT_RECORD=1 swift test` drafts an `.expected` file. **Read every caret line**
  before committing it, because a recorded file asserts whatever the engine did, right or wrong.
- Check `.build/fixture-report/index.html` (CI uploads it as the `fixture-report` artifact)
  to see the colouring.

### Engine lane: `Sources/` Swift code

Anything else under `Sources/`, plus `Package.swift`.

- Include a fixture or test that fails without the change.
- The full fixture suite and `PerformanceTests` must pass. Linearity is asserted on the
  scanner's work counter, so a matcher that backtracks or rescans fails there, not on a timer.
- Add a hostile input to `PerformanceTests` for any new matcher.
- The public API is UTF-16 `NSRange`s. Test multi-byte and emoji text.

## Rules for every PR

- **Original work only.** Don't translate or copy code, grammars or tests from other
  highlighters (TextMate, tree-sitter, Pygments, highlight.js…). TextMate grammars can't be
  adapted anyway, because this format has no regex. Other highlighters are fine to *compare
  output against*.
- **Apple frameworks only.** No new package dependencies.
- **Sign off every commit** ([Developer Certificate of Origin](https://developercertificate.org/)):
  `git commit -s`. CI's `dco` check fails a PR with an unsigned commit.
- **Use your GitHub noreply email** for commits (Settings → Emails). CI's `privacy` check
  fails any other address.
- **Conventional commits** (`feat:`, `fix:`, `docs:`, `test:`, `chore:`…). Versions and the
  changelog are generated from them, and PRs are squash-merged with the PR title as the commit.
- `swift test` passes locally.

## Review

- `main` needs an approving review from a code owner ([.github/CODEOWNERS](.github/CODEOWNERS)),
  and every review conversation must be resolved before merging.
- A push after an approval dismisses it, so re-request review when you change the PR.
- CI on a first-time contributor's PR waits for a maintainer to approve the workflow run.

## Reporting a security issue

See [SECURITY.md](SECURITY.md). Please don't open a public issue for one.
