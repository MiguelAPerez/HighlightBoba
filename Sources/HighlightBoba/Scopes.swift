import Foundation

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
        "entity.name.function",
        "support.type.property-name",
        "entity.other.attribute",
        "meta.preprocessor",
        "support.function",
        "punctuation",
        "punctuation.section.embedded",
        "invalid"
    ]

    /// Every scope name any loaded grammar uses, interned so tokens carry an `Int` instead of a `String`.
    final class Table: @unchecked Sendable {
        static let shared = Table()
        private let lock = NSLock()
        private var names: [String] = []
        private var ids: [String: Int] = [:]

        func id(for name: String) -> Int {
            lock.withLock {
                if let id = ids[name] { return id }
                names.append(name)
                ids[name] = names.count - 1
                return names.count - 1
            }
        }

        /// A snapshot of all names, indexed by id.
        var allNames: [String] { lock.withLock { names } }
    }
}
