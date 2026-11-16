//
//  SearchFields.swift
//  dbcon
//
//  Created by SITIS on 11/16/26.
//

import Foundation

enum SearchFields {
    struct Value {
        let selector: String
        let path: String
        let text: String
    }

    static func projection(_ fields: [String], available: [String]) throws -> String {
        try fields.map { field in
            let source: String
            if !available.contains(field), let wildcard = field.range(of: "[*]") {
                guard field.components(separatedBy: "[*]").count == 2 else { throw SearchSupport.fail(Errors.Search.arrayPath) }
                let prefix = String(field[..<wildcard.lowerBound])
                _ = try suffix(String(field[wildcard.upperBound...]))
                source = try QuerySQL.expression(prefix, available: available)
            } else { source = try QuerySQL.expression(field, available: available) }
            return "\(source) AS \(QuerySQL.quote(field))"
        }.joined(separator: ", ")
    }

    static func values(_ fields: [String], row: [String: Any], elementTypes: [String], typeField: String, literalFields: [String]) throws -> [Value] {
        var result: [Value] = []
        for field in fields {
            guard let raw = row[field] as? String else { continue }
            guard !literalFields.contains(field), let wildcard = field.range(of: "[*]") else {
                result.append(Value(selector: field, path: field, text: raw))
                continue
            }
            guard let data = raw.data(using: .utf8), let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { continue }
            let tail = try suffix(String(field[wildcard.upperBound...]))
            for (index, element) in array.enumerated() {
                if !elementTypes.isEmpty {
                    guard let object = element as? [String: Any], let type = object[typeField] as? String, elementTypes.contains(type) else { continue }
                }
                var value: Any? = element
                for token in tail {
                    switch token {
                    case let .name(name): value = (value as? [String: Any])?[name]
                    case let .index(index):
                        if let array = value as? [Any], array.indices.contains(index) { value = array[index] }
                        else { value = nil }
                    }
                }
                if let text = value as? String {
                    let path = String(field[..<wildcard.lowerBound]) + "[\(index)]" + String(field[wildcard.upperBound...])
                    result.append(Value(selector: field, path: path, text: text))
                }
            }
        }
        return result
    }

    private enum Token {
        case name(String)
        case index(Int)
    }

    private static func suffix(_ text: String) throws -> [Token] {
        var rest = Substring(text)
        var result: [Token] = []
        while let first = rest.first {
            rest.removeFirst()
            if first == "." {
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                guard !name.isEmpty else { throw SearchSupport.fail(Errors.Search.arrayPath) }
                result.append(.name(String(name)))
                rest = rest.dropFirst(name.count)
            } else if first == "[", let end = rest.firstIndex(of: "]"), let number = Int(rest[..<end]), number >= 0 {
                result.append(.index(number))
                rest = rest[rest.index(after: end)...]
            } else { throw SearchSupport.fail(Errors.Search.arrayPath) }
        }
        return result
    }
}
