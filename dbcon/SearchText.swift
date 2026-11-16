//
//  SearchText.swift
//  dbcon
//
//  Created by SITIS on 11/16/26.
//

import Foundation
import SQLite3

struct SearchText {
    struct Options {
        var ignoreCase = false
        var normalizeSpace = true
        var foldYo = false
        var match = "substring"
    }

    struct Hit {
        let start: Int
        let end: Int
        let quality: Int
        let method: String
    }

    let original: [Character]
    let normalized: String
    let characters: [Character]
    let positions: [Int]
    let options: Options

    init(_ text: String, options: Options) {
        self.options = options
        let input = Array(text)
        original = input
        var output = ""
        var mapping: [Int] = []
        for (index, character) in input.enumerated() {
            var part = String(character).precomposedStringWithCanonicalMapping
            if options.ignoreCase { part = part.lowercased(with: Locale(identifier: "en_US_POSIX")) }
            if options.foldYo {
                part = part.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
            }
            if options.normalizeSpace && character.isWhitespace {
                if output.last == " " { continue }
                part = " "
            }
            output += part
            mapping.append(contentsOf: repeatElement(index, count: part.count))
        }
        normalized = output
        characters = Array(output)
        positions = mapping
    }

    static func normalized(_ text: String, options: Options) -> String {
        SearchText(text, options: options).normalized
    }

    private static func word(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character.unicodeScalars.contains {
            CharacterSet.nonBaseCharacters.contains($0)
        }
    }

    private func originalHit(_ range: Range<Int>, quality: Int, method: String) -> Hit {
        Hit(start: positions[range.lowerBound], end: positions[range.upperBound - 1] + 1, quality: quality, method: method)
    }

    func find(_ query: String, phrase: Bool = false, literal: Bool = false) -> Hit? {
        let needle = Self.normalized(query, options: options)
        guard !needle.isEmpty else { return nil }
        if !literal, !phrase, options.match == "whole" {
            return normalized == needle ? originalHit(0..<characters.count, quality: 200, method: "whole") : nil
        }
        let pattern = Array(needle)
        if pattern.count <= characters.count {
            for start in 0...(characters.count - pattern.count) {
                let end = start + pattern.count
                guard characters[start..<end].elementsEqual(pattern) else { continue }
                let left = start == 0 || !Self.word(characters[start - 1])
                let right = end == characters.count || !Self.word(characters[end])
                if literal || (!phrase && options.match == "substring") || (left && right) {
                    let whole = start == 0 && end == characters.count
                    let quality = (left && right ? 140 : 100) + (whole ? 60 : 0)
                    return originalHit(start..<end, quality: phrase ? quality + 100 : quality, method: phrase ? "phrase" : "literal")
                }
            }
        }
        return nil
    }

    func snippet(around hit: Hit?, characters: Int) -> [String: Any] {
        let center = hit?.start ?? 0
        let lower = max(0, min(center - characters / 3, original.count - characters))
        let upper = min(original.count, lower + characters)
        return [
            "text": String(original[lower..<upper]),
            "start": lower, "end": upper,
            "truncated_before": lower > 0, "truncated_after": upper < original.count
        ]
    }

}

enum SearchPredicate {
    static func build(_ terms: [String], expressions: [String], available: [String], ignoreCase: Bool, exact: Bool) throws -> (filters: [String], parameters: [SQLValue]) {
        var filters: [String] = []
        var parameters: [SQLValue] = []
        for term in terms {
            let fields: [String]
            let value: String
            if let separator = term.firstIndex(of: "=") {
                let field = String(term[..<separator])
                guard !field.isEmpty else { throw Arguments.ArgumentError.invalid(Errors.Query.emptySearchField) }
                fields = [try QuerySQL.expression(field, available: available)]
                value = String(term[term.index(after: separator)...])
            } else { fields = expressions; value = term }
            let matches = fields.map { field -> String in
                parameters.append(.text(value))
                return "dbcon_match(\(field), ?, \(ignoreCase ? 1 : 0), \(exact ? 1 : 0))"
            }
            filters.append("(" + (matches.isEmpty ? "0" : matches.joined(separator: " OR ")) + ")")
        }
        return (filters, parameters)
    }
}

extension DatabaseInspector {
    func registerSearch() throws {
        let result = sqlite3_create_function(database, "dbcon_match", 4, SQLITE_UTF8, nil, { ctx, argc, argv in
            guard let ctx, let argv, argc == 4 else { return }
            guard sqlite3_value_type(argv[0]) != SQLITE_NULL,
                  let raw = sqlite3_value_text(argv[0]), let needle = sqlite3_value_text(argv[1]) else {
                sqlite3_result_int(ctx, 0)
                return
            }
            let value = String(decoding: UnsafeBufferPointer(start: raw, count: Int(sqlite3_value_bytes(argv[0]))), as: UTF8.self)
            let query = String(decoding: UnsafeBufferPointer(start: needle, count: Int(sqlite3_value_bytes(argv[1]))), as: UTF8.self)
            let options: String.CompareOptions = sqlite3_value_int(argv[2]) != 0 ? .caseInsensitive : []
            let exact = sqlite3_value_int(argv[3]) != 0
            let matches = exact ? value.compare(query, options: options) == .orderedSame : query.isEmpty || value.range(of: query, options: options) != nil
            sqlite3_result_int(ctx, matches ? 1 : 0)
        }, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(Errors.Database.preparingSearch) }
    }
}
