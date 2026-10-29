/// The scope names shipping grammars may emit. Themes style these; a test rejects anything else,
/// so a typo in a grammar fails CI instead of rendering as plain text.
public enum Scopes {
    public static let vocabulary: Set<String> = [
        "comment.line",
        "comment.block",
        "string.quoted",
        "constant.character.escape",
        "constant.numeric",
        "constant.language",
        "keyword",
        "variable.language",
        "entity.name.type",
        "entity.other.attribute",
        "meta.preprocessor",
        "support.function",
        "punctuation",
        "punctuation.section.embedded",
        "invalid"
    ]
}
