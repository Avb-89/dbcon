//
//  Query.swift
//  dbcon
//
//  Created by SITIS on 11/11/26.
//

import Foundation

enum SQLValue {
    case text(String)
    case integer(Int64)
    case real(Double)
}

struct QuerySQL {
    var projection = "*"
    var filter = "1"
    var order = ""
    var orderClause: String { order.isEmpty ? "" : " ORDER BY \(order)" }
    var parameters: [SQLValue] = []

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func nonEmptyFilter(columns: [String], available: [String]) throws -> String {
        let fields = columns == ["*"] ? available : columns
        let conditions = try fields.map { field -> String in
            let name = try expression(field, available: available)
            return "CASE typeof(\(name)) WHEN 'null' THEN 0 WHEN 'integer' THEN \(name) != 0 WHEN 'real' THEN \(name) != 0 WHEN 'blob' THEN length(\(name)) > 0 ELSE length(trim(\(name), char(9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288))) > 0 END"
        }
        return " AND (" + (conditions.isEmpty ? "0" : conditions.joined(separator: " OR ")) + ")"
    }

    static func expression(_ field: String, available: [String]) throws -> String {
        if available.contains(field) { return quote(field) }
        guard let separator = field.range(of: ":$"),
              available.contains(String(field[..<separator.lowerBound])) else {
            throw Arguments.ArgumentError.invalid("Unknown column or JSON field: \(field).")
        }
        let column = quote(String(field[..<separator.lowerBound]))
        let path = String(field[field.index(after: separator.lowerBound)...])
        guard path == "$" || path.hasPrefix("$.") || path.hasPrefix("$[") else {
            throw Arguments.ArgumentError.invalid("Invalid JSON path in \(field).")
        }
        let literal = "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
        return "CASE WHEN json_valid(\(column)) THEN json_extract(\(column), \(literal)) ELSE NULL END"
    }

    init(
        columns: [String],
        available: [String],
        terms: [String],
        conditions: [String],
        orderFields: [String],
        ignoreCase: Bool,
        exact: Bool
    ) throws {
        guard !columns.isEmpty, !columns.contains("*") || columns == ["*"] else {
            throw Arguments.ArgumentError.invalid("Provide column names or '*' alone.")
        }
        let selected = columns == ["*"] ? available : columns
        let expressions = try selected.map { try Self.expression($0, available: available) }
        if columns != ["*"] {
            projection = zip(expressions, selected).map { "\($0.0) AS \(Self.quote($0.1))" }.joined(separator: ", ")
        }
        var filters: [String] = []
        for term in terms {
            let fields: [String]
            let value: String
            if let separator = term.firstIndex(of: "=") {
                let field = String(term[..<separator])
                guard !field.isEmpty else { throw Arguments.ArgumentError.invalid("Search field must not be empty.") }
                fields = [try Self.expression(field, available: available)]
                value = String(term[term.index(after: separator)...])
            } else {
                fields = expressions
                value = term
            }
            let matches = fields.map { field in
                parameters.append(.text(value))
                return "dbcon_match(\(field), ?, \(ignoreCase ? 1 : 0), \(exact ? 1 : 0))"
            }
            filters.append("(" + (matches.isEmpty ? "0" : matches.joined(separator: " OR ")) + ")")
        }
        for condition in conditions {
            var parser = try WhereParser(condition, available: available)
            let parsed = try parser.parse()
            filters.append("(\(parsed))")
            parameters.append(contentsOf: parser.parameters)
        }
        if !filters.isEmpty { filter = filters.joined(separator: " AND ") }
        let sortFields = orderFields.flatMap { field in
            field.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !sortFields.contains(where: \.isEmpty) else { throw Arguments.ArgumentError.invalid("--order-by contains an empty field.") }
        order = try sortFields.map { try Self.orderItem($0, available: available) }.joined(separator: ", ")
    }

    private static func orderItem(_ text: String, available: [String]) throws -> String {
        if available.contains(text) { return "\(quote(text)) ASC" }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { throw Arguments.ArgumentError.invalid("--order-by requires a field.") }
        var direction = "ASC"
        var field = text
        if let last = parts.last?.uppercased(), last == "ASC" || last == "DESC" {
            direction = last
            field = String(text.dropLast(last.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !field.isEmpty else { throw Arguments.ArgumentError.invalid("Invalid sort field: \(text).") }
        return "\(try expression(field, available: available)) \(direction)"
    }
}

private struct WhereParser {
    private let tokens: [WhereToken]
    private let available: [String]
    private(set) var parameters: [SQLValue] = []
    private var index = 0

    init(_ text: String, available: [String]) throws {
        self.tokens = try Self.tokenize(text)
        self.available = available
    }

    mutating func parse() throws -> String {
        let result = try parseOr()
        guard index == tokens.count else { throw Arguments.ArgumentError.invalid("Unexpected text in --where.") }
        return result
    }

    private mutating func parseOr() throws -> String {
        var left = try parseAnd()
        while consumeWord("OR") {
            left = "(\(left) OR \(try parseAnd()))"
        }
        return left
    }

    private mutating func parseAnd() throws -> String {
        var left = try parsePrimary()
        while consumeWord("AND") {
            left = "(\(left) AND \(try parsePrimary()))"
        }
        return left
    }

    private mutating func parsePrimary() throws -> String {
        if consume("(") {
            let inner = try parseOr()
            guard consume(")") else { throw Arguments.ArgumentError.invalid("--where is missing a closing parenthesis.") }
            return "(\(inner))"
        }
        let field: String
        switch next() {
        case let .word(name)?, let .text(name)?: field = name
        default: throw Arguments.ArgumentError.invalid("--where requires a field.")
        }
        index += 1
        let expression = try QuerySQL.expression(field, available: available)
        if consumeWord("IS") {
            let negated = consumeWord("NOT")
            guard consumeWord("NULL") else { throw Arguments.ArgumentError.invalid("--where requires NULL after IS.") }
            return "\(expression) IS \(negated ? "NOT " : "")NULL"
        }
        guard let token = next(), case let .symbol(op) = token, ["=", "!=", "<>", ">", ">=", "<", "<="].contains(op) else {
            throw Arguments.ArgumentError.invalid("--where requires an operator.")
        }
        index += 1
        guard let value = next() else { throw Arguments.ArgumentError.invalid("--where requires a value.") }
        index += 1
        parameters.append(try bound(value))
        return "\(expression) \(op == "<>" ? "!=" : op) ?"
    }

    private func bound(_ token: WhereToken) throws -> SQLValue {
        switch token {
        case let .number(text):
            if let integer = Int64(text) { return .integer(integer) }
            guard text.contains(".") || text.lowercased().contains("e"),
                  let real = Double(text), real.isFinite else {
                throw Arguments.ArgumentError.invalid("Invalid or out-of-range number in --where: \(text). Quote text values.")
            }
            return .real(real)
        case let .text(text):
            return .text(text)
        case let .word(text):
            guard !["NULL", "AND", "OR", "IS", "NOT"].contains(text.uppercased()) else {
                throw Arguments.ArgumentError.invalid("Use IS NULL / IS NOT NULL for nulls; quote keyword text values in --where.")
            }
            return .text(text)
        case .symbol:
            throw Arguments.ArgumentError.invalid("--where requires a value after the operator.")
        }
    }

    private func next() -> WhereToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func consume(_ symbol: String) -> Bool {
        guard case let .symbol(value) = next(), value == symbol else { return false }
        index += 1
        return true
    }

    private mutating func consumeWord(_ word: String) -> Bool {
        guard case let .word(value) = next(), value.uppercased() == word else { return false }
        index += 1
        return true
    }

    private static func tokenize(_ text: String) throws -> [WhereToken] {
        var tokens: [WhereToken] = []
        var rest = Substring(text)
        while let character = rest.first {
            if character.isWhitespace {
                rest.removeFirst()
                continue
            }
            if character == "(" || character == ")" {
                tokens.append(.symbol(String(character)))
                rest.removeFirst()
                continue
            }
            if character == "'" || character == "\"" {
                let quote = character
                rest.removeFirst()
                var value = ""
                var closed = false
                while let next = rest.first {
                    rest.removeFirst()
                    if next == quote {
                        if rest.first == quote { value.append(quote); rest.removeFirst() }
                        else { closed = true; break }
                    } else { value.append(next) }
                }
                guard closed else { throw Arguments.ArgumentError.invalid("Unclosed quote in --where.") }
                tokens.append(.text(value))
                continue
            }
            if "!=<>".contains(character) {
                var op = String(character)
                rest.removeFirst()
                if rest.first == "=" || (character == "<" && rest.first == ">") {
                    op.append(rest.removeFirst())
                }
                tokens.append(.symbol(op))
                continue
            }
            var word = ""
            while let next = rest.first, !next.isWhitespace, !"()!=<>".contains(next) {
                word.append(next)
                rest.removeFirst()
            }
            guard !word.isEmpty else { throw Arguments.ArgumentError.invalid("Invalid --where syntax.") }
            if let first = word.first, first.isNumber || "+-.".contains(first) {
                guard word.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil else {
                    throw Arguments.ArgumentError.invalid("Invalid number in --where: \(word). Quote text values.")
                }
                tokens.append(.number(word))
            } else {
                tokens.append(.word(word))
            }
        }
        return tokens
    }
}

private enum WhereToken {
    case word(String)
    case text(String)
    case number(String)
    case symbol(String)
}
