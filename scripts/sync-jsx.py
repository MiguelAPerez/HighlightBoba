#!/usr/bin/env python3
"""Rebuilds the JSX and TSX grammars and queries from the JavaScript and TypeScript ones.

`Grammars/jsx.json` is `javascript.json` plus the JSX states (the ones named `jsx…`), with
`code` trying `jsxGuess` first; `tsx.json` is `typescript.json` with the same additions. Their
queries are the JSX queries (the ones that name a `jsx_` node kind) followed by the base
language's. The JSX parts are read from `jsx.json`, so edit them there, or edit the base files,
then run this:

    python3 scripts/sync-jsx.py

`JSXParserTests.grammarsAndQueriesMatchTheirBase` fails until the files are in sync.
"""

import json
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "HighlightBoba")


def load(kind, name):
    with open(os.path.join(ROOT, kind, name + ".json"), encoding="utf-8") as file:
        return json.load(file)


def save(kind, name, value):
    with open(os.path.join(ROOT, kind, name + ".json"), "w", encoding="utf-8") as file:
        file.write(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def is_jsx_query(query):
    kinds = []
    for key in ("in", "inside", "notInside"):
        value = query.get(key, [])
        kinds += [value] if isinstance(value, str) else value
    return any(kind.startswith("jsx_") for kind in kinds)


jsx_grammar = load("Grammars", "jsx")
jsx_states = {name: state for name, state in jsx_grammar["states"].items() if name.startswith("jsx")}
jsx_queries = [query for query in load("Queries", "jsx")["queries"] if is_jsx_query(query)]

for name, base, extensions in [("jsx", "javascript", ["jsx"]), ("tsx", "typescript", ["tsx"])]:
    grammar = load("Grammars", base)
    states = dict(grammar["states"])
    states.update(jsx_states)
    states["code"] = dict(states["code"], rules=[{"include": "jsxGuess"}] + states["code"]["rules"])
    save("Grammars", name, {
        "name": name,
        "fileExtensions": extensions,
        "initial": grammar["initial"],
        "wordCharacters": grammar["wordCharacters"],
        "states": {key: states[key] for key in sorted(states)},
    })
    save("Queries", name, {
        "format": 1,
        "language": name,
        "queries": jsx_queries + load("Queries", base)["queries"],
    })
