# Parser layer

Lexer grammars ([GRAMMAR.md](GRAMMAR.md)) give every language instant, linear highlighting. Languages where
context changes what a token means get a parser on top. It's hand-written recursive descent that builds a
lossless syntax tree, which highlight queries then use to refine scopes. This file covers the core the
parsers share. Highlight queries and incremental reparsing are next.

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
builder.expect(":")            // consumes it, or records "expected `:`"
parseValue(builder)
builder.finishNode()
let tree = builder.finish()
```

- **Reading:** `current`, `peek(n)`, `at("text")`, `at(scope:)` and `isAtEnd` only ever see
  significant tokens. `at("->")` also matches a run of adjacent tokens that spell it, since
  multi-character operators arrive as one-character symbols; trivia between them never matches. `at` compares whole tokens, so it never matches part of a longer lexeme, and it never matches trivia (`at(" ")`, `at("//")`).
- **Trivia:** trivia before a consumed token goes into the node that is open at the time. A node starts
  at its first significant token, so the trivia in front of it stays with its parent.
- **Left-associative operators:** take a `checkpoint()` before the left operand, then
  `startNode(kind, at: checkpoint)` wraps everything parsed since then, as rowan does. Trivia in front
  of the checkpoint stays outside the wrapper. Taking a checkpoint changes nothing in the tree, so one
  you never use costs nothing. A checkpoint is valid only in the node it was taken in, while that node
  is open; using it anywhere else stops the program.
- **Losslessness:** `finish()` puts every token the parser didn't consume into the root, so walking the
  leaves always gives the text back, even after a parser bug or an early stop.

`TreeBuilder(tokens:text:)` requires tokens that tile the text, as `syntaxTokens` does, and stops the program otherwise.

`SyntaxTree` is immutable and `Sendable`. `SyntaxNode` is a cheap handle that gives `kind`, `range`
(UTF-16), `text`, `parent`, `children`, `childNodes` and `tokens`. Kinds are names
(`SyntaxKind("call")`) that each parser declares, and highlight queries will match on those names.

## Errors and recovery

A parser never throws or stops at bad input. It records an error, wraps what it can't place in an
`error` node and carries on, so one typo costs the highlighting of one construct, not the rest of the
file. Errors are in `tree.errors`, in the order found. Each one's range is the significant token the
parser was looking at, or an empty range at the end of the text.

| Call | Does |
|------|------|
| `error("message")` | Records an error and consumes nothing. |
| `expect(")")` | Consumes `)` if it comes next; otherwise records "expected `)`" and consumes nothing. |
| `errorAndBump("message")` | Records an error and wraps the next significant token in an `error` node. |
| `recover("message", until: [";"])` | Records an error, then wraps everything up to the next `;` in an `error` node. |

`recover` skips `( )`, `[ ]` and `{ }` whole, so a `;` inside brackets doesn't stop it. It also never
consumes a closing bracket it didn't open, because that bracket belongs to an enclosing construct: a
block's statement loop gets its `}` back, even from `{ a ( b }` where the `(` is never closed. (A
closer for an outer bracket it did open closes the unclosed ones inside it.) At a stop token, a closing bracket or the end, it records
the error and skips nothing. So a loop that calls it must also handle a stray closing bracket itself,
usually with `errorAndBump`, or it makes no progress.

**A stuck parser stops.** After `TreeBuilder.maxStall` (4096) lookahead calls with nothing consumed,
the builder records "the parser stopped making progress here" and reads as at the end from then on.
A loop that never advances terminates, and `finish()` still puts every token in the tree.

**Nesting.** `depth` counts the open nodes. A recursive parser checks it and stops nesting (recording
an error) before its own call stack runs out on input like 100,000 `[`.

## Re-lexing

The lexer guesses context from the previous character: in JS, `/` after `)` reads as division. The
parser knows better. After `if (x)`, an expression starts, so that `/` opens a regex. `relex(as:)`
tells the lexer to read the next significant token starting with another grammar state's rules:

```swift
if builder.at("/"), expressionStarts { builder.relex(as: "regexStart") }
```

The grammar declares the state, like any other:

```json
"regexStart": { "rules": [{ "match": { "literal": "/" }, "scope": "string.regexp", "push": "regex" }] }
```

At that token, the lexer tries the state's rules before its current state's. Pushes and pops act on
the real stack. The lexer re-scans from the start of the line until its state matches what it had
before, which is usually the same line. The tokens the parser hasn't consumed yet are replaced.
`relex` returns `false` and changes nothing when:

- the builder has no highlighter,
- the grammar has no such state,
- none of the state's rules match at the token,
- the lexer doesn't start a step there, like the `>` of a `=>` it matched in one step,
- or the parse has used its budget, about four re-scans of the whole text.

The budget keeps a hostile file linear. A real file needs a handful of re-lexes.

Re-lexing applies to the host grammar only, not to grammars embedded in it. A re-lexed token that
turns out to be trivia (a comment) is skipped like any other.

**Applying it to the highlight.** The tree carries the lexing it ended with.
`highlighter.applyRelexing(of: tree)` makes the highlight match the tree and returns the ranges to
re-colour. Every parse starts from the lexer's own reading, so a token the previous parse re-lexed
and this one didn't goes back to normal. Edits move re-lexed tokens with their text, and drop one when
the edit replaces its first character. A tree from an older revision or another highlighter isn't
applied: `applyRelexing` returns `nil`.

## Off the main thread

`highlighter.snapshot` is a `Sendable` copy of the text and its lexing. Parse it anywhere with
`TreeBuilder(snapshot:)`, then hand the tree back to the highlighter's thread for `applyRelexing`:

```swift
let snapshot = highlighter.snapshot
let tree = await Task.detached { parse(TreeBuilder(snapshot: snapshot)) }.value
if let changed = highlighter.applyRelexing(of: tree) { recolour(changed) }
```
