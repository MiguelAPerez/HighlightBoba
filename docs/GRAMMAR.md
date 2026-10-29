# Grammar format

A grammar is a JSON file in `Sources/HighlightBoba/Grammars/<name>.json`. It describes a **pushdown state machine**: named states, each with an ordered list of rules. At each position the first rule that matches wins, emits a scope for the text it matched, then pushes a state, pops, or stays. The stack is what handles nesting: Swift's `/* /* */ */`, `\( )` interpolation containing strings, Python f-string `{}` fields.

It is **not** a regex engine and not a parser. Matchers come from a small closed set with no backtracking, so highlighting is linear in the input by construction.

```json
{
  "name": "json",
  "fileExtensions": ["json"],
  "initial": "value",
  "wordCharacters": "[A-Za-z0-9_]",
  "states": {
    "value": {
      "rules": [
        { "match": { "literal": "\"" }, "scope": "string.quoted", "push": "string" },
        { "match": { "words": ["true", "false", "null"] }, "scope": "constant.language" }
      ]
    },
    "string": {
      "scope": "string.quoted",
      "endsAtEOL": true,
      "rules": [
        { "match": { "seq": [{ "literal": "\\" }, { "class": "[\"\\\\/bfnrt]" }] }, "scope": "constant.character.escape" },
        { "match": { "literal": "\"" }, "pop": true }
      ]
    }
  }
}
```

## Top level

| Key | Meaning |
|-----|---------|
| `name` | Must match the file name. |
| `fileExtensions` | Extensions this grammar handles, without the dot. |
| `initial` | The state at the start of the document. |
| `wordCharacters` | Optional class used for word boundaries (`words`, `wordStarting`, `notAfterWord`). Default `[A-Za-z0-9_]`. |
| `states` | Named states. |

## States

| Key | Meaning |
|-----|---------|
| `rules` | Ordered rules. The first match wins. |
| `scope` | Optional. Text no rule matches gets this scope; rules without their own `scope` inherit it. |
| `endsAtEOL` | Optional. The state is popped at a line break (single-line strings). Other states carry across lines. |
| `endsAtDedent` | Optional. Pushed with `rememberIndent`; popped before any non-blank line indented no deeper than the line that pushed it (YAML block scalars). Blank lines don't end it. |

## Rules

| Key | Meaning |
|-----|---------|
| `match` | A matcher (below). |
| `scope` | The scope for the matched text. Defaults to the current state's scope. |
| `push` | A state to push after matching. |
| `pop` | `true` or a count of states to pop. Never pops the initial state. |
| `notAfterWord` | Only match when the previous character is not a word character. |
| `notAfter` | A class: only match when the previous non-blank character on the line is not in it. The line start counts as not-after. Tells a JS regex from division: `"notAfter": "[A-Za-z0-9_$)\\]]"`. |
| `captures` | For a `seq` matcher: one scope (or `null` for the rule's scope) per part. `func load` → `["keyword", null, "entity.name.function"]`. |
| `remember` | On a push: save the match (`true`) or one `seq` part (its index) on the new state, for `remembered` to close on. |
| `rememberIndent` | On a push: save the line's indentation, for `endsAtDedent`. |
| `embed` / `embedPart` | On a push: highlight the new state's text with another grammar, named directly (`"embed": "swift"`) or by a `seq` part's text (a fence's language tag). Names and file extensions both resolve. The pushed state's own rules are tried first at every position, so they act as the terminator. An unknown name falls back to the state's scope. |
| `include` | Instead of `match`: splice in another state's rules here. |

A rule that matches empty text is skipped unless it only pops, so a grammar can't loop.

## Matchers

Each matcher is an object with exactly one of these keys:

| Matcher | Matches |
|---------|---------|
| `{ "literal": "/*" }` | That exact text. |
| `{ "class": "[A-Za-z_]" }` | One character from the class. `^` negates; `\d`, `\w`, `\s`, `\n`, `\t`, `\r` and `\\` escapes work. BMP characters only. |
| `{ "repeat": "[0-9]", "min": 1, "max": 4 }` | A run of class characters, greedy, never gives any back. `min` defaults to 0, `max` to unbounded. |
| `{ "seq": [m1, m2] }` | Each matcher in turn. |
| `{ "opt": m }` | `m`, or nothing. |
| `{ "words": ["if", "else"] }` | One of those whole words (word boundaries on both sides). |
| `{ "wordStarting": "[A-Z]" }` | A whole word whose first character is in the class. |
| `{ "eol": true }` | Empty, at the end of a line. |
| `{ "bol": true }` | Empty, at the start of a line. |
| `{ "anyOf": [m1, m2] }` | The first alternative that matches. It commits: a later failure in the enclosing `seq` doesn't try the next alternative. |
| `{ "followedBy": m }` / `{ "notFollowedBy": m }` | Empty; succeeds if `m` does (or doesn't) match here. Nothing is consumed. |
| `{ "remembered": true }` | The text the current state's push rule saved with `remember`: heredoc terminators, Swift `#"…"#` hash counts, Markdown fence lengths. |

Nothing ever backtracks: `repeat` keeps its whole run, and `anyOf` keeps its first match. So `{"seq": [{"repeat": "[a-z]"}, {"literal": "ing"}]}` never matches `running`; write `followedBy` or split the rule instead.

### Patterns

- **Heredoc:** `{"seq":[{"literal":"<<"},{"opt":{"literal":"-"}},{"wordStarting":"[A-Za-z_]"}]}` with `"push":"heredoc","remember":2`, closed in `heredoc` by `{"seq":[{"bol":true},{"repeat":"[\\t]"},{"remembered":true},{"eol":true}]}`.
- **Fenced code:** remember the backtick run, `embedPart` the language tag, and close with `bol`, up to three spaces, `remembered`, then `{"repeat":"[`]"}` so a longer fence also closes it.
- **Keys vs values:** use states, not lookahead. JSON's grammar has `object`, `member` and `array` states, so a string is a key exactly when it appears where a key belongs.

## Scopes

Shipping grammars may only emit scopes in `Scopes.vocabulary` (`Sources/HighlightBoba/Scopes.swift`), so a typo fails CI instead of rendering as plain text:

`comment.line` `comment.block` `string.quoted` `constant.character.escape` `constant.numeric` `constant.language` `keyword` `variable.language` `entity.name.type` `entity.other.attribute` `meta.preprocessor` `support.function` `punctuation` `punctuation.section.embedded` `invalid`

## Fixtures

Every grammar has fixtures in `Tests/HighlightBobaTests/Fixtures/<name>/`: a `.input` file and a `.expected` file that copies each source line followed by one caret line per token on it.

```
let s = "a \(b)"
^^^ keyword
        ^^^ string.quoted
           ^^ punctuation.section.embedded
              ^ punctuation.section.embedded
               ^ string.quoted
```

Columns count characters, so carets line up under emoji. Ranges in the API are UTF-16. To draft a new `.expected` file, run `HIGHLIGHT_RECORD=1 swift test` — then **read every caret line** before committing it. A recorded file asserts whatever the engine did, right or wrong.

`swift test` also writes `.build/fixture-report/index.html`: every fixture coloured by scope, with expected vs actual for any mismatch. CI uploads it as an artifact.

## Known limits

- Python's line-continuation backslash inside single-quoted strings isn't modelled yet.
- Look-behind is limited to the current line: `notAfter` can't see a token on the previous line.
- Embedding nests at most four grammars deep, and a remembered delimiter is capped at 256 UTF-16 units.
- Interpolation inside a single-line string doesn't end at the line break; the string resumes after it.
