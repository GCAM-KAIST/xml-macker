import Foundation

/// A provider-neutral policy for moving source text into another app.
///
/// Chat web sites and macOS sharing extensions do not expose one common input
/// limit. xml-macker therefore offers a conservative excerpt for predictable
/// sharing, while leaving the full selection available as an explicit copy.
/// Excerpts always end between Swift `Character`s, so an extended grapheme
/// cluster (for example an emoji family or a letter plus combining marks) is
/// never split.
struct ShareTextExcerpt: Equatable {
    let text: String
    let totalUTF8Bytes: Int
    let includedUTF8Bytes: Int

    var omittedUTF8Bytes: Int { totalUTF8Bytes - includedUTF8Bytes }
    var isTruncated: Bool { omittedUTF8Bytes > 0 }
}

enum ShareTextPolicy {
    /// Roughly 32k tokens for ordinary text. This is deliberately described as
    /// a compatibility excerpt, not a limit guaranteed by any chat provider.
    static let compatibilityUTF8ByteLimit = 128 * 1024

    static func excerpt(
        from source: String,
        maximumUTF8Bytes: Int = compatibilityUTF8ByteLimit
    ) -> ShareTextExcerpt {
        let limit = max(0, maximumUTF8Bytes)
        let totalBytes = source.utf8.count
        guard totalBytes > limit else {
            return ShareTextExcerpt(
                text: source,
                totalUTF8Bytes: totalBytes,
                includedUTF8Bytes: totalBytes
            )
        }

        var end = source.startIndex
        var includedBytes = 0
        while end < source.endIndex {
            let next = source.index(after: end) // advances by one Character
            let characterBytes = source[end..<next].utf8.count
            guard includedBytes + characterBytes <= limit else { break }
            includedBytes += characterBytes
            end = next
        }

        return ShareTextExcerpt(
            text: String(source[..<end]),
            totalUTF8Bytes: totalBytes,
            includedUTF8Bytes: includedBytes
        )
    }
}
