# Changelog

## 0.2.0 (2026-10-31)

### Feat

- Python parser and highlight queries (#16)
- shell parser and highlight queries (#18)
- JavaScript and TypeScript parser, with highlight queries (#14)
- Swift parser and highlight queries (#15)
- parser core, part 4: incremental block reparse, off the main thread (#13)
- parser core, part 3: highlight queries (format v1) (#12)
- parser core, part 2: error recovery and re-lex requests (#11)
- parser core, part 1: syntax tokens, lossless tree and builder (#10)
- backslash line continuation, and single-line states end with what they contain (#6)

### Fix

- **test**: parse session gate no longer fills the thread pool (#17)
- coverage tours for Swift, Python, JavaScript and JSON, and what they found (#9)
- coverage tours for shell, Markdown and YAML, and what they found (#8)
- number literals with signed exponents, leading dots and radix prefixes (#7)

## 0.1.0 (2026-10-29)

### Feat

- JavaScript, TypeScript, Go, YAML, Markdown and shell grammars (#3)
- grammar format v1 and flat compiled grammars (#2)
- grammar-driven highlighting engine with JSON, Swift and Python (#1)

## 0.0.0 (2026-10-28)

- Initial package skeleton.
