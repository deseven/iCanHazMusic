// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A piece of information about the playing track that a text template (`TextTemplate`) can use, written as
/// `{name}`.
enum TemplateVariable: String, CaseIterable, Identifiable, Sendable {
    case artist
    case title
    case album
    case year
    case track

    var id: String { rawValue }

    /// How it is written in a template.
    var token: String { "{\(rawValue)}" }

    var help: String {
        switch self {
        case .artist: "Artist of the track"
        case .title: "Title of the track"
        case .album: "Album the track is from"
        case .year: "Year of the album"
        case .track: "Number of the track in the album"
        }
    }
}

/// The text of a now playing component (`Title`, `Subtitle`) as the user wrote it, with variables in braces:
/// `{artist} – {title}`.
///
/// - A variable the track has no value for is empty. When that happens, brackets that end up with nothing between
///   them are dropped and the spaces around are tidied, so `{album} ({year})` is `Album` for an album without a year
///   (and not `Album ()`). A template whose variables all have values is used exactly as written.
/// - `\{` is a literal `{`, so `\{artist}` shows `{artist}`.
/// - Everything else that isn't a known variable (`{nonsense}`, a lone `}`) is shown as written. Names are matched
///   regardless of case.
enum TextTemplate {
    static func render(_ template: String, values: [TemplateVariable: String]) -> String {
        var result = ""
        var hadEmpty = false
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if character == "\\", next < template.endIndex, template[next] == "{" {
                result.append("{")
                index = template.index(after: next)
            } else if character == "{", let close = template[next...].firstIndex(of: "}"),
                      let variable = TemplateVariable(rawValue: template[next..<close].lowercased()) {
                let value = values[variable] ?? ""
                if value.isEmpty { hadEmpty = true }
                result += value
                index = template.index(after: close)
            } else {
                result.append(character)
                index = next
            }
        }
        return hadEmpty ? tidied(result) : result
    }

    /// Removes `()` and `[]` with nothing (or only spaces) in them, collapses runs of spaces and trims the ends.
    private static func tidied(_ text: String) -> String {
        var text = text
        for pattern in [#"\(\s*\)"#, #"\[\s*\]"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

extension PlaybackState.TrackInfo {
    /// What a `TextTemplate` can show about the track.
    var templateValues: [TemplateVariable: String] {
        [.artist: artist, .title: title, .album: album, .year: year ?? "", .track: number.map(String.init) ?? ""]
    }
}
