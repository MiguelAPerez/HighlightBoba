import Foundation

/// How close the thread a parse runs on is to the end of its stack, for a recursive parser's
/// nesting limit to fall back on.
///
/// A parser's depth limit is what keeps a reparse's tree the same as a whole parse's, but a
/// frame's size depends on the build: a debug build's are several times a release build's, and a
/// background thread may have only 512 KB (an iOS secondary thread's default). So each parser
/// also stops nesting when the stack runs low, whatever the depth. Made at the start of a parse,
/// on the thread that runs it; a parse never changes threads, since it never suspends.
struct StackGuard {
    /// Stack kept free below where the parser stops nesting: enough for its recovery and for the
    /// builder's `finish()`, with room to spare.
    static let reserve: UInt = 160 * 1024
    /// The lowest stack address the parse may recurse to, or 0 where the stack can't be measured.
    private let floor: UInt

    init() {
        #if canImport(Darwin)
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        floor = top > size + Self.reserve ? top - size + Self.reserve : 0
        #else
        floor = 0
        #endif
    }

    /// Whether the stack is down to its reserve: the parser should stop nesting.
    var isLow: Bool {
        var marker = 0
        return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) } < floor
    }
}
