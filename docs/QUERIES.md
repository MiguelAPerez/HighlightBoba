# Highlight queries (format v1)

A parser ([PARSER.md](PARSER.md)) builds a syntax tree. Highlight queries say what the tree means
for colour: the word after `fn` names a function, the first word of a call is the function being
called. They are data, one JSON file per language, compiled once and run over every tree.

Queries only **refine scopes on tokens that already exist**. Each one gives a whole token of the tree
a new scope. It never splits, merges or adds a token, so running queries changes the colour of the
tokens they match and nothing else.

```json
{
  "format": 1,
  "language": "toy",
  "queries": [
    { "in": ["name", "function"], "scope": "entity.name.function" },
    { "kind": "word", "in": ["call"], "index": 0, "scope": "support.function" },
    { "text": "self", "kind": "word", "scope": "variable.language" },
    { "in": ["parameter"], "scope": "variable.other" },
    { "in": "error", "scope": "invalid" }
  ]
}
```

## Top level

| Key | Meaning |
|-----|---------|
| `format` | `1`. A file with any other format is rejected. |
| `language` | The language the queries are for. |
| `queries` | The queries, in order. |

## Queries

A query matches one token. Every condition it has must hold, and it needs at least one that
narrows it: `notInside`, or an `in` made only of `"*"`, only rule tokens out, so neither is enough
alone. Unknown keys are rejected, so a typo fails to load instead of quietly
matching more than it should.

| Key | The token… |
|-----|------------|
| `scope` | Required. The scope the token gets. |
| `text` | …is this text, or one of a list of texts: `"self"`, `["get", "set"]`. One whole token; `->` spelled by two symbols doesn't match. |
| `kind` | …is a `"lexeme"` (the lexer scoped it), a `"word"` (identifier) or a `"symbol"` (an unscoped operator or bracket). See [Tokens](PARSER.md#tokens). |
| `lexerScope` | …has this scope from the lexer, or one under it: `"string"` matches `string.quoted`, not `stringy`. |
| `in` | …sits in nodes of these kinds, from its parent outward: `["name", "function"]` is a token whose parent is a `name` node inside a `function` node. `"*"` stands for any node. A single kind may be written without the array. |
| `index` | …is this child of its parent, counting from 0 and skipping trivia; negative counts from the end (`-1` is the last). Child nodes count as one child each. |
| `after` | …directly follows a sibling token with this text (trivia between them doesn't count). |
| `before` | …is directly followed by a sibling token with this text. |
| `inside` | …has an ancestor of each of these kinds, at any depth. |
| `notInside` | …has no ancestor of any of these kinds. |

Kinds are the names a parser gives its nodes (`SyntaxKind("call")`), plus `root` and `error`.
There are no field names in v1. A parser that wants one wraps that child in a node of its own
kind, as the toy parser wraps a function's name in a `name` node, and `in` matches it.

**Trivia never matches.** Spaces, line breaks and comments keep the lexer's scope.

**Siblings are tokens.** `after` and `before` look at the token's neighbours in the same parent.
A neighbour that is a node is not a token, so it never matches.

## Precedence

The **first query that matches a token wins**, as the first rule that matches wins in a grammar. Put the
specific queries first: `{"text": "self"}` before `{"in": ["parameter"]}` makes a `self` parameter
`variable.language`. A query that gives a token the scope it already has still wins: it stops the
later queries and leaves the token as it is.

## Error nodes

What a parser couldn't place sits in an `error` node ([recovery](PARSER.md#errors-and-recovery)), and
the tree around it says little about what those tokens are. So a token inside an `error` node, at any
depth, matches only queries that name `error` in `in` or `inside`. Everything else leaves it with the
lexer's scope, so one typo never paints a stray word as a function name.

## Running them

```swift
let queries = try HighlightQueries(data: json)        // once per language
let tree = parse(TreeBuilder(highlighter: highlighter))
_ = highlighter.applyRelexing(of: tree)
let refinement = queries.run(on: tree)                // or run(on: node), for one block
let tokens = highlighter.tokens(refinedBy: refinement) // nil if the text changed since the parse
```

`ScopeRefinement.overrides` lists the tokens that get a new scope, in text order; each range is
exactly one token of the tree. `apply(to:)` lays them over the lexer's spans. It cuts a lexer span
only where an override starts or ends, which happens when the override is one character of a
punctuation run the lexer coloured in one span. An override on text the lexer left unscoped, an
identifier, becomes a span of its own. Every other position keeps exactly the lexer's scope.

**One node.** `run(on: node)` checks only the tokens under `node`, but still sees the nodes above it,
so its overrides are exactly the whole-tree run's overrides inside `node.range`. A block reparse can
re-run the queries for the block it rebuilt and nothing else. The result covers only that block:
to keep the rest of the file's overrides, replace the old ones inside `range` with it.

**Cost.** A run is linear in the size of the tree. It walks the tree once, iteratively, so a deep
tree can't overflow the stack. A token is checked against the queries that can match its kind, in
order, and no check depends on the size or depth of the tree: `in` looks at as many ancestors as the
query names, `text` compares against the texts it lists, and `inside` and `notInside` read a count
of the open nodes of each kind, however deep the token is. `run(on: node)` first walks up from the
node once, to learn its context. There is no regex anywhere.
