# Parser layer

Lexer grammars ([GRAMMAR.md](GRAMMAR.md)) give every language instant, linear highlighting. Languages where
context changes what a token means get a parser on top. It's hand-written recursive descent that builds a
lossless syntax tree, which highlight queries then use to refine scopes. This file covers the core the
parsers share, from tokens to incremental reparsing.

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
(`SyntaxKind("call")`) that each parser declares, and highlight queries match on those names.

## Highlight queries

Highlight queries are data that map tree patterns (a node kind, a child's position, its ancestors,
a token's text or lexer scope) to scopes. They only give existing tokens a new scope, so they never
re-tokenise. Format v1 is specified in [QUERIES.md](QUERIES.md).

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

- the builder has no highlighter, or the parser is at the end (or stuck),
- the grammar has no such state,
- none of the state's rules match at the token,
- the lexer doesn't start a step there, like the `>` of a `=>` it matched in one step,
- or the parse has used its budget, about four re-scans of the whole text. A request that is refused
  after the lexer looked still counts against it.

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

## Incremental reparsing

After an edit, a parser reparses only the smallest block around it, and the result is exactly the
tree a whole parse would build. A language opts in with `IncrementalParser`:

```swift
struct SwiftParser: IncrementalParser {
    var reparseBoundaries: Set<SyntaxKind> { [codeBlock, arrayLiteral] }
    func parse(_ builder: TreeBuilder) { /* the whole file */ }
    func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) { /* one `kind` node, from its first token */ }
}

let result = parser.reparse(oldTree, after: highlighter.edit(since: oldTree.textRevision)!, in: highlighter.snapshot)
result.tree        // the new tree
result.changed     // the node that was rebuilt: re-run highlight queries on just this
```

A **reparse boundary** is a node kind whose parse depends only on its own tokens: a `{ }` body, an
array literal. `parseBlock` must parse one such node exactly as `parse` would have, whatever is
around it, and must start it with `startNode(kind)`, not at a checkpoint.

`Highlighter.edit(since:)` folds the edits since a revision into one `TextEdit`: the range it replaced in
the old text and how long the new text is. It remembers the last 1024 edits.

### When a block is enough

The reparse walks from the innermost node around the edit outwards and takes the first boundary
where every one of these holds. If none does, it parses the whole text.

- The edit is strictly inside the block: its first and last tokens (`{` and `}`) are untouched and
  lex the same. Typing just before `{` or just after `}` belongs to the enclosing block.
- Lookahead before the block started read no further than its first token, so the parse leading up
  to it decided nothing from the edited text.
- The block's parse ends exactly at its old last token and never looks past it. Inserting a stray
  `}` ends the block early, and an extra `[` in a list takes its `]` and reads on, so both fall back. An
  unclosed `(` that recovery closes at the list's `]` stays inside it.
- The lexer agrees about what follows: the rest of the block's last line lexes as before, and that
  line hands the next one the same state. Opening a string that runs past the block falls back.
- Re-lexing stays inside: the block's own requests re-scan no line past its last, no request made
  outside it re-scanned the edited text, and the whole parse stays inside its re-lex budget.

Then everything after the block parses as before, so its nodes are moved by the edit's length, not
rebuilt. The tree stores what the checks need on each node (its depth, how far lookahead had read,
the errors and re-lex requests made inside it), so they cost the block, not the file.

**Cost.** Parser work is proportional to the block: a one-line edit in a 2,000-block file does
about 1/1000 of a whole parse's lookahead. Splicing the subtree in copies the tree's flat tables
and moving the offsets after it is linear in the file, but that is memory work, far cheaper than parsing.

### Parsing in the background

`ParseSession` keeps a tree for a highlighter, parsing on a background task:

```swift
let session = ParseSession(highlighter: highlighter, parser: SwiftParser())
session.onUpdate = { update in
    recolour(update.relexed)                   // re-lexing the tree asked for, already applied
    rerunQueries(on: update.changed)           // the rebuilt block, or the root
}
highlighter.replaceCharacters(in: range, with: text)
session.textDidChange()
```

`textDidChange()` takes a `Sendable` snapshot, cancels the parse that is running, and starts one
that covers every edit since the last published tree. The builder notices cancellation within a
few thousand lookahead steps and stops early. A result is published, on the main actor, only if
it is the newest parse and the text is still the revision it was parsed from. Anything older is
dropped, never applied over newer text.
