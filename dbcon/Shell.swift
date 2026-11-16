//
//  Shell.swift
//  dbcon
//
//  Created by SITIS on 11/11/26.
//

import Darwin
import Foundation

enum Shell {
    static func run(inspector: DatabaseInspector, readOnly: Bool) throws {
        let prompt = readOnly ? "read-only:>> " : "write:>> "
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        var batch = ""
        defer {
            if inspector.hasTransaction {
                print(Errors.Shell.rollbackOnExit)
                do { try inspector.cancelChanges() }
                catch { report(error.localizedDescription) }
            }
        }
        while true {
            if interactive && batch.isEmpty {
                print(prompt, terminator: "")
                fflush(stdout)
            }
            guard let line = readLine() else {
                if !batch.isEmpty { print(Errors.Shell.unfinishedCommand) }
                return
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let word = trimmed.lowercased()
            if batch.isEmpty, ["quit", "exit", "quit;", "exit;"].contains(word) { return }
            if batch.isEmpty, ["save", "cancel", "save;", "cancel;"].contains(word) {
                runBatch(trimmed, inspector: inspector, readOnly: readOnly)
                continue
            }
            let combined = batch.isEmpty ? trimmed : batch + "\n" + trimmed
            if let command = terminatedCommand(combined) {
                runBatch(command, inspector: inspector, readOnly: readOnly)
                batch = ""
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
        print(Errors.format(message))
        fflush(stdout)
    }

    private static func execute(_ raw: String, inspector: DatabaseInspector, readOnly: Bool) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return }
        let control = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch control {
        case "save":
            try inspector.saveChanges()
            return
        case "cancel":
            try inspector.cancelChanges()
            return
        default: break
        }
        let prefix = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = prefix.first?.lowercased() else { return }
        let tail = prefix.count > 1 ? String(prefix[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let helper = ["tables", "columns", "count", "search"].contains(first)
        let flagStyle = isFlagPrefix(first)
        let selectFlags = first == "select" && startsWithSelectFlag(tail)
        if !helper && !flagStyle && !selectFlags {
            try inspector.executeSQLBatch(text)
            return
        }
        var tokens = try tokenize(text)
        switch first {
        case "tables":
            guard tokens.count == 1 else { throw ShellError.invalid(Errors.Shell.tablesAlone) }
            tokens = ["--tables"]
        case "columns": tokens = ["--columns", "-t"] + Array(tokens.dropFirst())
        case "count": tokens = ["--count", "-t"] + Array(tokens.dropFirst())
        case "search": tokens[0] = "-s"
        case "select":
            tokens.removeFirst()
        default:
            guard first.hasPrefix("-") else { throw ShellError.invalid(Errors.Shell.unknownCommand) }
        }
        let arguments = try Arguments(tokens, inShell: true)
        if let command = arguments.searchCommand {
            try SearchCLI.run(command, inspector: inspector)
            return
        }
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
        case .insert, .update, .delete:
            try inspector.write(arguments, inShell: true)
        default: throw ShellError.invalid(Errors.Shell.actionRequired)
        }
    }

    private static func startsWithSelectFlag(_ text: String) -> Bool {
        guard let token = text.split(whereSeparator: \.isWhitespace).first else { return false }
        if SearchCLI.isAdvanced([String(token)]) { return true }
        return ["-t", "--table", "--tables", "-c", "--column", "-n", "-f", "-s", "--search",
                "-i", "-e", "-ie", "-ei", "--eq", "--equal", "--where", "--order-by", "--sort", "--read"].contains(String(token))
    }

    private static func isFlagPrefix(_ token: String) -> Bool {
        if SearchCLI.isAdvanced([token]) { return true }
        if !token.hasPrefix("--") { return token.hasPrefix("-") }
        return ["--config", "--set-config", "--mcp", "--db", "--tables", "--table",
                "--column", "--columns", "--read", "--search", "--where", "--order-by",
                "--sort", "--man", "--help", "--timeout", "--count", "--non-empty",
                "--eq", "--equal", "--insert", "--update", "--delete", "--values", "--set"].contains(token)
    }

    private static func terminatedCommand(_ text: String) -> String? {
        guard text.suffix(2).lowercased() == "go" else { return nil }
        let prefix = String(text.dropLast(2))
        guard prefix.isEmpty || prefix.last?.isWhitespace == true else { return nil }
        var quote: Character?
        var escaped = false
        let characters = Array(prefix)
        let words = prefix.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let first = words.first?.lowercased() ?? ""
        let flagInput = isFlagPrefix(first) || ["tables", "columns", "count", "search"].contains(first)
            || (first == "select" && words.count > 1 && startsWithSelectFlag(String(words[1])))
        var index = 0
        var lineComment = false
        var blockComment = false
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            index += 1
            if lineComment {
                if character == "\n" { lineComment = false }
                continue
            }
            if blockComment {
                if character == "*", next == "/" { blockComment = false; index += 1 }
                continue
            }
            if escaped { escaped = false; continue }
            if flagInput, character == "\\", quote != "'" { escaped = true; continue }
            if let delimiter = quote {
                if character == delimiter {
                    if next == delimiter, delimiter != "]" { index += 1 }
                    else { quote = nil }
                }
            } else if character == "-", next == "-" {
                if !flagInput { lineComment = true; index += 1 }
            } else if character == "/", next == "*" {
                blockComment = true
                index += 1
            } else if character == "[" { quote = "]" }
            else if character == "'" || character == "\"" || character == "`" { quote = character }
        }
        return quote == nil && !escaped && !lineComment && !blockComment ? prefix : nil
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
        guard quote == nil, !escaped else { throw ShellError.invalid(Errors.Shell.unclosedQuote) }
        if started { tokens.append(token) }
        return tokens
    }

}
