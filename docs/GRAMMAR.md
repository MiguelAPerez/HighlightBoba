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
| `embed` | Optional. A grammar that highlights the whole document beneath this one, as PHP's `"embed": "html"` does: the initial state's rules are tried first at every position, and text they don't match goes to the embedded grammar, whose state survives the pushes and pops above it. Counts toward the embedding depth cap. |
| `wordCharacters` | Optional class used for word boundaries (`words`, `wordStarting`, `notAfterWord`). Default `[A-Za-z0-9_]`. |
| `states` | Named states. |

## States

| Key | Meaning |
|-----|---------|
| `rules` | Ordered rules. The first match wins. |
| `scope` | Optional. Text no rule matches gets this scope; rules without their own `scope` inherit it. |
| `endsAtEOL` | Optional. The state ends at a line break (single-line strings), and so does everything nested in it: an unclosed Swift `"\(` interpolation ends with its string. Other states carry across lines. |
| `spansLines` | Optional. Shields the states below it from `endsAtEOL`: a Python f-string field may cross a line break, so its string survives one too. States nested in it still end at the break if they are `endsAtEOL`. |
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
| `embedState` | With `embed` or `embedPart`: start the guest in this state of its grammar instead of its initial one. HTML's `style="…"` attribute embeds CSS starting in `declarations`, since an attribute holds declarations, not rules. An unknown state falls back to the initial one. |
| `pushAtNextLine` | On a push: enter the state at the end of this line instead of now, so the rest of the line stays in the current state. Several on one line are entered in the order they appeared (`cat <<A <<B`: A's body, then B's). |
| `continuesLine` | When the match reaches the line end, the line break doesn't end `endsAtEOL` states: backslash continuation, `{"seq":[{"literal":"\\"},{"eol":true}]}`. |
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
- **Raw text up to a closing tag:** HTML's `<script>` pushes a body state that embeds JavaScript and whose only rule is the case-insensitive `</script` followed by a space, `/`, `>` or the line end. The host's rules come first, so the body ends there even inside a JavaScript string, as it does in a browser. The `type` attribute picks the body: its rule pops the tag state and pushes a sibling whose `>` pushes the JSON or raw-text body instead.
- **Islands in a document:** PHP's initial state has only the `<?php`, `<?=` and `<?` openers, and its `embed` hands everything else to HTML. An opener pushes `code`, whose `?>` pops back, so HTML resumes exactly where it was, even mid-attribute (`href="<?= $u ?>"`) or inside an embedded script. Without a `?>` the file stays PHP to the end.
- **Keys vs values:** use states, not lookahead. JSON's grammar has `object`, `member` and `array` states, so a string is a key exactly when it appears where a key belongs.

## Scopes

Shipping grammars may only emit scopes in `Scopes.vocabulary` (`Sources/HighlightBoba/Scopes.swift`), so a typo fails CI instead of rendering as plain text:

`comment.line` `comment.block` `string.quoted` `constant.character.escape` `constant.numeric` `constant.language` `keyword` `variable.language` `entity.name.type` `entity.name.function` `entity.name.tag` `support.type.property-name` `entity.other.attribute` `meta.preprocessor` `support.function` `punctuation` `punctuation.section.embedded` `invalid` `string.regexp` `variable.other` `variable.other.enummember` `variable.parameter` `markup.heading` `markup.bold` `markup.italic` `markup.raw` `markup.link` `markup.inserted` `markup.deleted`

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

## JSX and TSX

`jsx.json` and `tsx.json` are generated: `javascript.json` and `typescript.json`, plus the states
named `jsx…` from `jsx.json`, with `code` trying `jsxGuess` first. Edit the base grammar, or the
JSX states in `jsx.json`, then run `python3 scripts/sync-jsx.py`; a test fails while they differ.
The same script prepends the JSX queries to each base language's queries.

- `jsxGuess` opens an element at a `<` before a name or `>` (`notAfter` an operand), or after
  `return`, `yield` and the like. It leaves `<T,>` and `<T extends` alone, for TSX's generic arrows.
- `jsxTag`, `jsxChildren` and `jsxClosingTag` are the element's: a tag's `>` replaces its state with
  the children's (`"pop": 1` with `"push"`), and a closing tag's `>` pops both. `jsxExpression` is
  code up to its `}`; `jsxTypeArguments` reads TSX's `<List<T>`.
- `jsxStart`, `jsxLessThan`, `jsxLineString` and `jsxPop1`…`jsxPop32` exist only for the parser's
  re-lex requests ([PARSER.md](PARSER.md#jsx-and-tsx)). A `jsxPop` state's one rule matches empty
  text and only pops, which a rule may do.

## Known limits

These are the lexer's. Where a language has a parser ([PARSER.md](PARSER.md#bundled-parsers)), it fixes the ones that need context: in JavaScript and TypeScript, regex versus division across lines, keyword-like names and keys, and `void` as an operator; in JSX and TSX, an element versus `<`; in shell, command position (`echo done`), a `case` pattern's `)` inside `$( )`, a `<<` shift in arithmetic and a `<<\EOF` heredoc.

- Look-behind is limited to the current line: `notAfter` can't see a token on the previous line.
- Shell: a `#` right after a closing quote (`"a"#b`) starts a comment, though the shell reads it as part of the word. A comment is trivia, so the shell parser ([PARSER.md](PARSER.md#shell)) can't re-lex it.
- Lexers don't know what a name is for: Swift's scopes `get`, `some` or `async` as keywords wherever they appear, and every capitalized word as a type. Swift's parser fixes these ([PARSER.md](PARSER.md#swift)).
- Markdown has no look-ahead to a closing delimiter, so an unclosed `*`, `_` or `` ` `` colours to the end of the line; setext heading text (the line above `===`) isn't scoped, only the underline; and indented code isn't told apart from list continuation. Without the previous line, a lone `===` after a blank line still reads as a setext underline, `a[i][j]` in prose reads as a reference link, and an HTML block inside a blockquote (`> <div>`) isn't recognised. HTML block tag names are matched in lower, UPPER or Title case only, so a mixed-case `<dIv>` reads as inline HTML.
- An unterminated YAML quote runs on until the next matching quote, because YAML quoted strings may span lines.
- Markdown strikethrough, tables and entities, and YAML timestamps, have no scope in the vocabulary, so they stay plain.
- Python: an f-string field left open (`f"{a`) runs on to the next `}`, past its line. Soft keywords are guessed from the line alone; the parser decides them (see [PARSER.md](PARSER.md#python)).
- JSX: an attribute whose value is an element (`<a b=<c />>`) isn't read, and neither is a namespace spaced out (`<svg : rect>`). Inside one root, elements nest at most 31 deep (`jsxPop32` is the most the parser can pop at once); a `<` deeper than that reads as text. A `<` the lexer guessed wrong is fixed only when the parse runs ([PARSER.md](PARSER.md#jsx-and-tsx)).
- JSON numbers are checked only for trailing ASCII letters: `1é` isn't flagged, and neither is a bare `-x`. Also unflagged: `01`, `1.` and `.5`.
- CSS: a name and a colon start a declaration unless a `{` follows on the same line, which makes them a nested rule's selector (`a:hover {`). So a nested selector list split across lines (`a:hover,` then `b {` on the next line) reads its first line as a declaration. Rules at the top level of a stylesheet or of `@media` are never mistaken for declarations, only rules nested in a style block. Non-ASCII outside the BMP (emoji) in a class or id name isn't scoped as part of it.
- HTML: a lexer doesn't track which elements are open, so a `<![CDATA[` section is recognised anywhere, not only inside SVG or MathML. `<script>` types are matched in lower case only (`text/JavaScript` stays raw text), and a second `type` after a JavaScript one switches the body again, where a browser keeps the first. Event handler attributes (`onclick="…"`) embed JavaScript, but entities in them (`&quot;`) aren't decoded first. Framework attributes (`:style`, `@click`, `v-bind:style`) stay plain strings.
- PHP: `<?` alone opens PHP, as if `short_open_tag` were on. Keywords and `true`/`false`/`null` are matched in lower, UPPER or Title case only, so `ElseIf` isn't a keyword. A name and a colon after `(`, `,` or at a line start read as a named argument, so a `goto` label at a line start (`end:`) does too. Class names are recognised by shape: a capital followed somewhere by a lower-case letter, so `PHP_EOL` stays a constant but a lower-case class name isn't scoped. A ```` ```php ```` fence in Markdown without `<?php` reads as HTML, as the file would. Tags that PHP itself prints (`<<?= $tag ?>>`) aren't seen by HTML, and data after `__halt_compiler();` is still highlighted as PHP.
- Diff: a hunk doesn't count its lines, so it ends at the first line that can't belong to one (not a space, `+`, `-` or `\`). Inside a hunk `--- x` is a removed line, so a second file's `---` header reads as one unless a `diff` or `Index:` line comes first, as git, `diff -r` and Subversion all write. Outside a hunk, `+` and `-` lines read as added and removed, for fragments without headers. The second column of a combined diff (`++`, ` -`) isn't coloured.
- TOML: dates and times are scoped as numbers, and a malformed number (`1-2`, `1__0`) isn't flagged. Inline tables may span lines, as TOML 1.1 allows.
- Dockerfile: `# escape=` is coloured as a directive but doesn't change the escape character, so a backtick continuation isn't recognised; directives are recognised anywhere, not only at the top of the file. Shell-form `RUN`, `CMD` and `ENTRYPOINT` are highlighted by the shell lexer, without its parser, so a keyword-like argument (`echo done`) colours as a keyword. A `RUN` heredoc body is shell; any other heredoc body (`COPY <<EOF`) is a plain string. Instructions are matched in lower, UPPER or Title case only.
- SQL: one grammar for the common dialects (standard SQL, PostgreSQL, MySQL, SQLite). Keywords are matched in lower, UPPER or Title case only, and a keyword used as a column name (`key`, `type`) still reads as a keyword. A string may span lines, as SQL allows, so an unclosed `'` runs on to the next quote. Block comments nest, as standard SQL and PostgreSQL have them; MySQL's `#` comments and SQL Server's `[bracketed]` names aren't recognised, and a `$$` body is a plain string, not highlighted as code.
- XML: names outside the BMP aren't recognised. An attribute value ends at a `<`, which XML forbids in one, so an unclosed quote doesn't swallow the rest of the document. A DTD's internal subset is coloured by declaration, not parsed.
- Rust: a `'` followed by up to two characters and a `'` reads as a char literal, so a lifetime directly followed by a quote (`'a'b`) isn't told apart. Every capitalized word is a type except SCREAMING_CASE constants, which stay plain, and a lone capital (`T`) is a type. Format strings (`"{x:?}"`) aren't scoped inside, and a macro's body is read as ordinary code.
- C and C++: `.h` files read as C. A lexer can't tell a type name from a variable, so only the built-in types, the common `<stdint.h>` ones (`size_t`, `uint8_t`…) and names after `struct`, `class`, `enum`, `union`, `namespace` and `concept` are types; a `typedef` name (`point_t`) isn't. A preprocessor line is coloured as code, with a trailing `\` continuing it, and a directive's `#` is only recognised at a line start. A raw string delimiter is capped at 16 characters, as the standard allows. A C++ user-defined literal suffix is coloured with its number (`10ms`) but stays plain after a string (`"abc"s`).
- Embedding nests at most four grammars deep, and a remembered delimiter is capped at 256 UTF-16 units.
