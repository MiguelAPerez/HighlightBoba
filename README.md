# HighlightBoba

A grammar-driven syntax highlighter for Swift, written from scratch with Apple frameworks only.

**Status:** early. The engine works, with grammars for Swift, Python, JavaScript, TypeScript, Go, JSON, YAML, Markdown (fenced code highlighted in its own language) and shell. The API may still change.

```swift
import HighlightBoba

let grammar = try Grammar.bundled("swift")
let highlighter = Highlighter(grammar: grammar, text: source)
for token in highlighter.tokens {
    // token.range is a UTF-16 NSRange; token.scope is e.g. "keyword"
}
let changed = highlighter.replaceCharacters(in: editedRange, with: replacement) // re-scans only what the edit affects
```

Grammars are data: a small pushdown state machine per language, matched without regex or backtracking. See [docs/GRAMMAR.md](docs/GRAMMAR.md).

## Contributing

**Issues welcome, PRs not yet.** Bug reports, language requests and design feedback are very welcome as issues. Pull requests from outside contributors will open once the grammar format is stable; until then they will be closed without review. See [CONTRIBUTING.md](CONTRIBUTING.md) for how the data and engine lanes will work, and [SECURITY.md](SECURITY.md) to report a vulnerability privately.

## License

MIT. See [LICENSE](LICENSE).

## Versioning

Releases follow semver, driven by [Commitizen](https://commitizen-tools.github.io/commitizen/) and conventional commits; `cz.yaml` is the source of truth. A maintainer runs the **Release PR** workflow, reviews and merges the bump PR, and **Release Publish** then tags the version and creates the GitHub release. Pin the package to an exact tag.
