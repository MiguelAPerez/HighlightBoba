# Parser layer

Lexer grammars ([GRAMMAR.md](GRAMMAR.md)) give every language instant, linear highlighting. Languages where
context changes what a token means get a parser on top. It's hand-written recursive descent that builds a
lossless syntax tree, which highlight queries then use to refine scopes. This file covers the core the
parsers share. Recovery helpers, re-lexing, highlight queries and incremental reparsing are next.

## Tokens

`Highlighter.syntaxTokens` is the stream a parser reads. It is the lexer's tokens, with the gaps
between them filled. Parsers never run a second tokenizer.

| Kind | What |
|------|------|
| `lexeme` | A token the lexer scoped; `scope` names it (`keyword`, `string.quoted`, `comment.line`…). Punctuation-scoped tokens are split one per character, because the lexer merges runs like `]}],`. |
| `word` | An unscoped run of the grammar's `wordCharacters`, or of any non-ASCII character: identifiers. |
| `symbol` | One unscoped character that isn't a word character or a space: operators and brackets. |
| `space` | A run of spaces and tabs. |
| `newline` | `\n`, `\r` or `\r\n`. |

The tokens tile the text: every UTF-16 unit is in exactly one, in order. Spaces, line breaks and
comments are **trivia** (`isTrivia`). The stream is rebuilt from the highlighter's per-line state, so it
follows `replaceCharacters`.

## Building a tree

```swift
let builder = TreeBuilder(highlighter: highlighter)
builder.startNode(SyntaxKind("member"))
builder.bump()                 // the key
builder.bump(":")              // consumes it only if it comes next
parseValue(builder)
builder.finishNode()
let tree = builder.finish()
```

- **Reading:** `current`, `peek(n)`, `at("text")`, `at(scope:)` and `isAtEnd` only ever see
  significant tokens. `at("->")` also matches a run of adjacent tokens that spell it, since
  multi-character operators arrive as one-character symbols; trivia between them never matches.
- **Trivia:** trivia before a consumed token goes into the node that is open at the time. A node starts
  at its first significant token, so the trivia in front of it stays with its parent.
- **Left-associative operators:** take a `checkpoint()` before the left operand, then
  `startNode(kind, at: checkpoint)` wraps everything parsed since then, as rowan does.
- **Losslessness:** `finish()` puts every token the parser didn't consume into the root, so walking the
  leaves always gives the text back, even after a parser bug or an early stop.

`SyntaxTree` is immutable and `Sendable`. `SyntaxNode` is a cheap handle that gives `kind`, `range`
(UTF-16), `text`, `parent`, `children`, `childNodes` and `tokens`. Kinds are names
(`SyntaxKind("call")`) that each parser declares, and highlight queries will match on those names.
