//
//  Shell.swift
//  dbcon
//
//  Created by SITIS on 11/11/26.
//

import Darwin
import Foundation

enum Shell {
    private enum ShellError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(message):
                return message
            }
        }
    }

    static func run(inspector: DatabaseInspector, readOnly: Bool) throws {
        let prompt = readOnly ? "read-only:>> " : "write:>> "
        var batch = ""
        while true {
            print(prompt, terminator: "")
            fflush(stdout)
            guard let line = readLine() else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let word = trimmed.lowercased()
            if word == "quit" || word == "exit" { return }
            if batch.isEmpty, let blocked = blockedCommand(word, readOnly: readOnly) {
                report(blocked)
                continue
            }
            let combined = batch.isEmpty ? trimmed : batch + "\n" + trimmed
            if let command = terminatedCommand(combined) {
                runBatch(command, inspector: inspector, readOnly: readOnly)
                batch = ""
                continue
            }
            if batch.isEmpty, let problem = immediateProblem(trimmed) {
                report(problem)
                continue
            }
            batch = combined
        }
    }

    private static func runBatch(_ batch: String, inspector: DatabaseInspector, readOnly: Bool) {
        do {
            try execute(batch, inspector: inspector, readOnly: readOnly)
        } catch {
            report(error.localizedDescription)
        }
    }

    private static func report(_ message: String) {
        print("Error: \(message)")
        fflush(stdout)
    }

    private static func blockedCommand(_ word: String, readOnly: Bool) -> String? {
        let command = word.split(whereSeparator: \.isWhitespace).first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ";")).lowercased() } ?? ""
        let control = ["save", "cancel"]
        let writes = ["insert", "update", "delete", "create", "drop", "alter", "replace"]
        guard control.contains(command) || writes.contains(command) else { return nil }
        if readOnly {
            return "The shell is read-only. SAVE, CANCEL, and write statements are rejected."
        }
        return "SAVE, CANCEL, and write statements are not available yet."
    }

    private static func immediateProblem(_ line: String) -> String? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first?.lowercased() else { return nil }
        let known = [
            "select", "tables", "columns", "count", "--count", "--columns", "--column", "--table", "--read", "--search", "--where", "--order-by", "--sort", "search", "-s", "-c", "-t", "-n", "-f", "-i", "-e", "-ie", "-ei", "--eq", "--equal",
            "save", "cancel", "insert", "update", "delete", "create", "drop", "alter", "replace"
        ]
        guard known.contains(first) || first.hasPrefix("-") else {
            return "Unknown command. Use SELECT, TABLES, COLUMNS, or -s."
        }
        let needsValue = ["-t": "a table name", "--table": "a table name", "-c": "column names", "--column": "column names", "-n": "a row limit", "-s": "search text", "--search": "search text", "--where": "a condition", "--order-by": "fields", "--sort": "fields"]
        if let expected = needsValue[first], tokens.count < 2 {
            return "\(tokens[0]) requires \(expected)."
        }
        if first == "columns", tokens.count < 2 {
            return "COLUMNS requires a table name."
        }
        if first == "count", tokens.count < 2 {
            return "COUNT requires a table name."
        }
        return nil
    }

    private static func execute(_ raw: String, inspector: DatabaseInspector, readOnly: Bool) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return }
        var tokens = try tokenize(text)
        guard let first = tokens.first?.lowercased() else { return }
        if let blocked = blockedCommand(first, readOnly: readOnly) {
            throw ShellError.invalid(blocked)
        }
        switch first {
        case "tables":
            guard tokens.count == 1 else { throw ShellError.invalid("Use TABLES alone to list tables.") }
            tokens = ["--tables"]
        case "columns": tokens = ["--columns", "-t"] + Array(tokens.dropFirst())
        case "count": tokens = ["--count", "-t"] + Array(tokens.dropFirst())
        case "search": tokens[0] = "-s"
        case "select":
            tokens.removeFirst()
            if let next = tokens.first, !next.hasPrefix("-") { tokens = try sqlArguments(tokens) }
        default:
            guard first.hasPrefix("-") else { throw ShellError.invalid("Unknown command. Use SELECT, TABLES, COLUMNS, COUNT, or -s.") }
        }
        let arguments = try Arguments(tokens, inShell: true)
        switch arguments.action {
        case .tables: try inspector.listTables()
        case .columns: try inspector.showColumns(tables: arguments.tableNames)
        case .count:
            try inspector.countRows(tables: arguments.tableNames, columns: arguments.columnNames, nonEmpty: arguments.nonEmpty, queries: arguments.searchTexts, conditions: arguments.whereTexts, ignoreCase: arguments.ignoreCase, exact: arguments.exact)
        case .search:
            try inspector.searchTables(
                tables: arguments.tableNames, columns: arguments.columnNames,
                queries: arguments.searchTexts, conditions: arguments.whereTexts,
                orderFields: arguments.orderFields, ignoreCase: arguments.ignoreCase,
                exact: arguments.exact, compact: arguments.compact, rowLimit: arguments.rowLimit
            )
        case .read:
            try inspector.readTables(
                tables: arguments.tableNames, columns: arguments.columnNames,
                conditions: arguments.whereTexts, orderFields: arguments.orderFields,
                compact: arguments.compact, rowLimit: arguments.rowLimit
            )
        default: throw ShellError.invalid("Specify a table and an action inside the shell.")
        }
    }

    private static func sqlArguments(_ tokens: [String]) throws -> [String] {
        guard let from = tokens.firstIndex(where: { $0.lowercased() == "from" }), from > 0, from + 1 < tokens.count else {
            throw ShellError.invalid("SQL SELECT requires FROM <table>.")
        }
        var flags = ["-t", tokens[from + 1], "-c"] + Array(tokens[..<from])
        var index = from + 2
        let valued = ["-n", "-s", "--search", "--where", "--order-by", "--sort"]
        while index < tokens.count {
            let token = tokens[index].lowercased() == "limit" ? "-n" : tokens[index]
            guard token.hasPrefix("-") else { throw ShellError.invalid("Unknown SQL tail: \(tokens[index]). Use --where and --order-by for filtering and sorting.") }
            flags.append(token)
            if valued.contains(token) {
                index += 1
                guard index < tokens.count else { throw ShellError.invalid("\(token) requires a value.") }
                flags.append(tokens[index])
            }
            index += 1
        }
        return flags
    }

    private static func terminatedCommand(_ text: String) -> String? {
        guard text.suffix(2).lowercased() == "go" else { return nil }
        let prefix = String(text.dropLast(2))
        guard prefix.isEmpty || prefix.last?.isWhitespace == true else { return nil }
        var quote: Character?
        var escaped = false
        for character in prefix {
            if escaped { escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let delimiter = quote {
                if character == delimiter { quote = nil }
            } else if character == "'" || character == "\"" { quote = character }
        }
        return quote == nil && !escaped ? prefix : nil
    }

    private static func tokenize(_ text: String) throws -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in text {
            if escaped { token.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let delimiter = quote {
                if character == delimiter { quote = nil } else { token.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { tokens.append(token); token = ""; started = false }
            } else {
                token.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else { throw ShellError.invalid("Unclosed quote or trailing escape.") }
        if started { tokens.append(token) }
        return tokens
    }

}
