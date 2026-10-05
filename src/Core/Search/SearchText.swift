import Foundation

/// Text prepared for matching: case, accents and character width folded away, as UTF-16 units (cheap to compare and
/// keep around, unlike `String`).
typealias SearchString = ContiguousArray<UInt16>

enum SearchText {
    static func fold(_ text: String) -> SearchString {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return SearchString(folded.utf16)
    }

    /// The words of a query, folded. Every one of them has to be found.
    static func tokens(of query: String) -> [SearchString] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// The words as one text, separated by single spaces: what a whole name is compared with.
    static func normalized(_ words: [SearchString]) -> SearchString {
        var result = SearchString()
        for (i, word) in words.enumerated() {
            if i > 0 { result.append(32) }
            result.append(contentsOf: word)
        }
        return result
    }

    /// Letters and digits (anything outside ASCII counts as a letter) make words; the rest separates them.
    static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 122) || unit > 127
    }

    static func isWordStart(_ text: SearchString, at index: Int) -> Bool {
        index == 0 || !isWordUnit(text[index - 1])
    }
}

/// How well a query word was found in one field.
struct FieldMatch {
    /// The word is in the field as it is typed; otherwise it was found by fuzzy matching.
    let isExact: Bool
    /// Higher is better; only comparable between matches of the same kind.
    let score: Int
}

/// Finding a query word in a field.
///
/// - *Exact*: the word is a part of the field. Better if it is the whole field, at its start or at the start of a
///   word, and if the field is short.
/// - *Fuzzy* (only if it isn't exact): the letters of the word are in the field in this order, close together
///   (`pfloyd` finds `Pink Floyd`), or the word is one of the field's words with a typo or two (`floid`, `pnik`).
///   Words of one or two letters are only ever matched exactly.
enum FuzzyMatcher {
    /// The best match of `word` in any of `fields`: an exact one if there is one, else a fuzzy one. `nil` if none.
    static func best(of word: SearchString, in fields: [SearchString]) -> FieldMatch? {
        var best: Int?
        for field in fields {
            if let score = exact(word, in: field), score > (best ?? Int.min) { best = score }
        }
        if let best { return FieldMatch(isExact: true, score: best) }

        for field in fields {
            if let score = fuzzy(word, in: field), score > (best ?? Int.min) { best = score }
        }
        return best.map { FieldMatch(isExact: false, score: $0) }
    }

    /// Every word of the query has to be found in one of the fields (not necessarily the same). The result is exact
    /// if all words were found exactly; the score is the sum of the words'. `nil` if one word isn't found at all.
    static func match(_ words: [SearchString], in fields: [SearchString]) -> FieldMatch? {
        total(words.map { best(of: $0, in: fields) })
    }

    /// The matches of all the words of a query as one: `nil` if there are none or a word has none.
    static func total(_ hits: [FieldMatch?]) -> FieldMatch? {
        var isExact = true
        var score = 0
        for hit in hits {
            guard let hit else { return nil }
            if !hit.isExact { isExact = false }
            score += hit.score
        }
        return hits.isEmpty ? nil : FieldMatch(isExact: isExact, score: score)
    }

    /// The better of two matches of a word: an exact one beats a fuzzy one, then the higher score.
    static func better(_ a: FieldMatch?, _ b: FieldMatch?) -> FieldMatch? {
        guard let a else { return b }
        guard let b else { return a }
        if a.isExact != b.isExact { return a.isExact ? a : b }
        return a.score >= b.score ? a : b
    }

    // MARK: Exact

    static func exact(_ needle: SearchString, in text: SearchString) -> Int? {
        let m = needle.count, n = text.count
        guard m > 0, m <= n else { return nil }

        var bonus: Int?
        var i = 0
        while i <= n - m {
            if text[i] == needle[0] {
                var j = 1
                while j < m, text[i + j] == needle[j] { j += 1 }
                if j == m {
                    let here = n == m ? 300 : i == 0 ? 200 : SearchText.isWordStart(text, at: i) ? 100 : 0
                    if here > (bonus ?? Int.min) { bonus = here }
                    if here == 300 { break }
                }
            }
            i += 1
        }
        guard let bonus else { return nil }
        return 1000 + bonus - min(n - m, 99)
    }

    // MARK: Fuzzy

    static func fuzzy(_ needle: SearchString, in text: SearchString) -> Int? {
        let a = subsequence(needle, in: text)
        let b = typo(needle, in: text)
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// The letters of `needle` in `text` in this order, within a stretch not much longer than the word.
    static func subsequence(_ needle: SearchString, in text: SearchString) -> Int? {
        let m = needle.count, n = text.count
        guard m >= 3, m <= n else { return nil }
        let maxSpan = m + m / 2 + 1

        var best: Int?
        for start in 0..<n where text[start] == needle[0] {
            let limit = min(n, start + maxSpan)
            var matched = 1
            var end = start
            var i = start + 1
            while matched < m, i < limit {
                if text[i] == needle[matched] {
                    matched += 1
                    end = i
                }
                i += 1
            }
            guard matched == m else { continue }
            let span = end - start + 1
            let score = 500 - (span - m) * 40 + (SearchText.isWordStart(text, at: start) ? 60 : 0) - min(n - m, 99) / 4
            if score > (best ?? Int.min) { best = score }
        }
        return best
    }

    /// `needle` is a word of `text` with one typo (two for long words): a letter wrong, missing, extra or two
    /// swapped.
    static func typo(_ needle: SearchString, in text: SearchString) -> Int? {
        let m = needle.count
        let allowed = m >= 8 ? 2 : m >= 4 ? 1 : 0
        guard allowed > 0 else { return nil }

        var best: Int?
        var i = 0
        let n = text.count
        while i < n {
            guard SearchText.isWordUnit(text[i]) else {
                i += 1
                continue
            }
            var end = i
            while end < n, SearchText.isWordUnit(text[end]) { end += 1 }
            if abs((end - i) - m) <= allowed,
               let distance = editDistance(needle, text[i..<end], limit: allowed) {
                let score = 300 - 80 * distance - min(n - m, 99) / 4
                if score > (best ?? Int.min) { best = score }
            }
            i = end
        }
        return best
    }

    /// Optimal string alignment distance (insertions, deletions, substitutions and swaps of neighbours), `nil`
    /// if it is above `limit`.
    static func editDistance(_ a: SearchString, _ b: ArraySlice<UInt16>, limit: Int) -> Int? {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return max(n, m) <= limit ? max(n, m) : nil }
        let start = b.startIndex

        // Three rows of the table (two rows back is needed for the swaps), without allocating on the heap.
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (m + 1)) { rows -> Int? in
            var twoAgo = rows.baseAddress!
            var previous = twoAgo + (m + 1)
            var current = previous + (m + 1)
            for j in 0...m {
                twoAgo[j] = 0
                previous[j] = j
            }
            for i in 1...n {
                current[0] = i
                var rowMin = i
                for j in 1...m {
                    let cost = a[i - 1] == b[start + j - 1] ? 0 : 1
                    var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                    if i > 1, j > 1, a[i - 1] == b[start + j - 2], a[i - 2] == b[start + j - 1] {
                        value = min(value, twoAgo[j - 2] + 1)
                    }
                    current[j] = value
                    rowMin = min(rowMin, value)
                }
                if rowMin > limit { return nil }
                (twoAgo, previous, current) = (previous, current, twoAgo)
            }
            return previous[m] <= limit ? previous[m] : nil
        }
    }
}
