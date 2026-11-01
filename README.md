# HighlightBoba

A grammar-driven syntax highlighter for Swift, written from scratch with Apple frameworks only.

**Status:** early. The engine works, with grammars for Swift, Python, JavaScript, TypeScript, JSX, TSX, Go, JSON, YAML, TOML, Dockerfile, unified diffs, Markdown (fenced code highlighted in its own language), shell, CSS, HTML (with `<style>`, `<script>` and `style="…"` highlighted as CSS, JavaScript or JSON) and PHP (its islands in HTML). The API may still change.

```swift
import HighlightBoba

let grammar = try Grammar.bundled("swift")
let highlighter = Highlighter(grammar: grammar, text: source)
for token in highlighter.tokens {
    // token.range is a UTF-16 NSRange; token.scope is e.g. "keyword"
}
let changed = highlighter.replaceCharacters(in: editedRange, with: replacement) // re-scans only what the edit affects
```

Grammars are data: a small pushdown state machine per language, matched without regex or backtracking. See [docs/GRAMMAR.md](docs/GRAMMAR.md). For the languages that need context (Swift, JavaScript/TypeScript, JSX/TSX, Python and shell), a parser layer on top refines those colours; see [docs/PARSER.md](docs/PARSER.md).

## Themes

A `HighlightTheme` says how tokens draw: a background, a text colour and a style (colour, bold, italic) per scope selector. A selector styles its scope and every dotted scope under it, so `"string"` covers `string.quoted` and `string.regexp`, and the longest matching selector wins. Themes are `Codable`, with `#RRGGBB` colours.

```swift
let theme = try JSONDecoder().decode(HighlightTheme.self, from: data).readable(ratio: 4.5)
let styles = theme.stylesByScope // look up once, then style each token by token.scope
```

`readable(ratio:)` raises any colour below a WCAG contrast ratio on the theme's background just far enough to reach it, keeping its hue.

## Contributing

**Pull requests are welcome.** So are bug reports, language requests and design feedback as issues. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: every PR belongs to the data lane (grammars, fixtures, queries) or the engine lane (Swift code), and both need a fixture or test that fails without the change. To report a vulnerability privately, see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

## Versioning

Releases follow semver, driven by [Commitizen](https://commitizen-tools.github.io/commitizen/) and conventional commits; `cz.yaml` is the source of truth. A maintainer runs the **Release PR** workflow, reviews and merges the bump PR, and **Release Publish** then tags the version and creates the GitHub release. Pin the package to an exact tag.
