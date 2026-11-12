//
//  Man.swift
//  dbcon
//
//  Created by SITIS on 11/11/26.
//

import Darwin
import Foundation

enum Man {
    static let connectionHint = "Add --db /path/base.db, select a configuration with --config <path>, or save a default with --set-config."

    static let help = """
    dbcon - SQLite database utility

    USAGE
      dbcon
      dbcon --db <file> [-r|-w] [--timeout <ms>]
      dbcon --db <file> -r -t <table> -c <columns> [-n <count>] [-f]
      dbcon --set-config
      dbcon --man [en|ru]

    CONNECTION
      --db, -db <file>      Open a database directly.
      --config <file>       Use a configuration for this run.
      --set-config          Create or select the default configuration.
      -r / -w               Read-only / read-write. Default: -r.
      --timeout <ms>        Busy wait. Default 3000. Minimum 1000.

    ONE-SHOT
      -t <table>            Table to read or search.
      -c, --column <names>  Output fields; also limits plain-text search.
                            JSON field: 'data:$.text'. Default: all.
      --columns -t <table>  List columns and their structure.
      --count -t <table>    Count rows. Can be combined with -s.
      -p, --non-empty       Count non-empty rows. Only with --count.
                            Use -c to choose fields checked for emptiness.
      -n <count>            Maximum rows.
      --where <expr>        Row filter. Repeat for AND. = != > >= < <=
      --order-by <fields>   Sort fields. ASC is the default; DESC optional.
      --sort <fields>       Alias for --order-by.
      -s, --search <text>   Search text or field=value. Repeat for AND.
                            Field search is independent of output fields.
      -f                    One row per record.
      -i                    Ignore case for all search conditions.
      -e, --eq, --equal     Match the whole value for all conditions.
      -ie                   Same as -i -e. Only these flags can be grouped.

    SHELL
      No action: interactive shell. GO executes; QUIT or EXIT leaves.

    MCP
      --mcp                Read-only MCP server over stdio (JSON-RPC).

    EXAMPLE
      dbcon --db ./work.db -r -t session -c id,title -n 1000 -f

      -h, --help            Show this help.
      --man [en|ru]         Print the full manual.
    """

    private enum ManualError: LocalizedError {
        case missing
        case missingSection(String)

        var errorDescription: String? {
            switch self {
            case .missing:
                return "Manual file Man.txt was not found."
            case let .missingSection(language):
                return "Manual file Man.txt has no \(language) section."
            }
        }
    }

    static func manual(language: String) throws -> String {
        let text = try loadText()
        guard let section = section(text, language: language) else {
            throw ManualError.missingSection(language)
        }
        return render(section, color: isatty(STDOUT_FILENO) != 0)
    }

    private static func loadText() throws -> String {
        for url in searchURLs() where FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw ManualError.missing
    }

    private static func searchURLs() -> [URL] {
        var urls: [URL] = []
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(executable.appendingPathComponent("Man.txt"))
        }
        if let resource = Bundle.main.url(forResource: "Man", withExtension: "txt") {
            urls.append(resource)
        }
        urls.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Man.txt"))
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Man.txt"))
        return urls
    }

    private static func section(_ text: String, language: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let marker = "@language \(language)"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
            return nil
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("@language ") }) ?? lines.endIndex
        return lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ text: String, color: Bool) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        while index < lines.count {
            if isTableRow(lines[index]) {
                var rows: [String] = []
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(lines[index])
                    index += 1
                }
                output.append(renderTable(rows, color: color))
            } else {
                output.append(renderLine(lines[index], color: color))
                index += 1
            }
        }
        return output.joined(separator: "\n")
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|")
    }

    private static func renderLine(_ line: String, color: Bool) -> String {
        if line.hasPrefix("## ") {
            return paint(String(line.dropFirst(3)), "1;36", color: color)
        }
        if line.hasPrefix("# ") {
            return paint(String(line.dropFirst(2)), "1;97", color: color)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("dbcon ") {
            let indent = String(line.prefix { $0 == " " })
            return indent + paint(trimmed, "36", color: color)
        }
        return renderInline(line, color: color)
    }

    private static func renderInline(_ line: String, color: Bool) -> String {
        var result = ""
        var rest = Substring(line)
        while let start = rest.range(of: "**") {
            result += rest[..<start.lowerBound]
            rest = rest[start.upperBound...]
            guard let end = rest.range(of: "**") else {
                result += "**"
                result += rest
                return result
            }
            result += paint(String(rest[..<end.lowerBound]), "1;33", color: color)
            rest = rest[end.upperBound...]
        }
        result += rest
        return result
    }

    private static func renderTable(_ rows: [String], color: Bool) -> String {
        let parsed = rows.map(cells).filter { row in
            !row.allSatisfy { $0.isEmpty || $0.allSatisfy { $0 == "-" } }
        }
        guard parsed.count > 1 else {
            return ""
        }
        var lines: [String] = []
        for row in parsed.dropFirst() {
            let name = row.first ?? ""
            let detail = row.dropFirst().joined(separator: " ")
            lines.append("  " + paint(name, "1;32", color: color))
            for piece in wrap(detail, width: 66) where !piece.isEmpty {
                lines.append("      " + piece)
            }
            lines.append("")
        }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func cells(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        if parts.first?.isEmpty == true {
            parts.removeFirst()
        }
        if parts.last?.isEmpty == true {
            parts.removeLast()
        }
        return parts
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        if text.isEmpty {
            return []
        }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let piece = String(word)
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= width {
                current += " " + piece
            } else {
                lines.append(current)
                current = piece
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func paint(_ text: String, _ code: String, color: Bool) -> String {
        color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text
    }
}
