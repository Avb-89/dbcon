//
//  SearchCLI.swift
//  dbcon
//
//  Created by SITIS on 11/16/26.
//

import Foundation

enum SearchCLI {
    struct Command {
        let tool: String
        let arguments: [String: Any]
        let json: Bool
        let compact: Bool
    }

    private static let options: [String: String] = [
        "--key": "key_columns", "--group-by": "group_by", "--require": "required_groups",
        "--phrase": "phrases", "--exclude": "exclude", "--priority": "priority_columns",
        "--element-type": "element_types", "--element-type-field": "element_type_field",
        "--window": "window_rows", "--max-gap": "max_gap_seconds", "--per-group": "per_group", "--match": "match", "--mode": "mode", "--rank": "sort",
        "--offset": "offset", "--snippet": "snippet_chars", "--max-bytes": "max_bytes", "--meta": "metadata_columns",
        "--time-column": "time_column", "--time-unit": "time_unit", "--time-zone": "time_zone",
        "--anchor": "anchor_where", "--before": "before", "--after": "after",
        "--source-table": "source_table", "--source-field": "source_field", "--related-field": "related_field"
    ]
    private static let switches: Set<String> = ["--find", "--context", "--json", "--full", "--fold-yo", "--literal-space"]

    static func isAdvanced(_ values: [String]) -> Bool {
        let singleValues: Set<String> = ["--db", "-db", "--config", "--timeout", "--search", "-s", "--where", "--order-by", "--sort", "-n", "--values", "--set"]
        var index = 0
        while index < values.count {
            let value = values[index]
            if options[value] != nil || switches.contains(value) { return true }
            index += singleValues.contains(value) ? 2 : 1
        }
        return false
    }

    static func parse(_ values: [String], inShell: Bool) throws -> Arguments {
        var base: [String] = []
        var request: [String: Any] = [:]
        var seen = Set<String>()
        var index = 0
        var context = false
        var find = false
        var json = false
        var compact = false
        let arrays: Set<String> = ["key_columns", "group_by", "required_groups", "phrases", "exclude", "priority_columns", "element_types", "metadata_columns", "anchor_where", "search"]
        let names: Set<String> = ["key_columns", "group_by", "priority_columns", "metadata_columns"]
        let numbers: Set<String> = ["window_rows", "max_gap_seconds", "per_group", "offset", "snippet_chars", "max_bytes", "before", "after"]
        func assign(_ key: String, value: String) throws {
            if arrays.contains(key) {
                var items = request[key] as? [String] ?? []
                items += names.contains(key) ? value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } : [value]
                request[key] = items
            } else {
                guard seen.insert(key).inserted else { throw SearchSupport.fail(Errors.CLI.duplicateOption(key)) }
                if numbers.contains(key) {
                    guard let number = Int(value) else { throw SearchSupport.fail(Errors.Search.optionValue) }
                    request[key] = number
                } else { request[key] = value }
            }
        }
        func take(_ flag: String) throws -> String {
            guard index < values.count, !values[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !values[index].contains("\0") else { throw SearchSupport.fail(Errors.CLI.valueRequired(flag)) }
            let value = values[index]
            index += 1
            return value
        }
        while index < values.count {
            let flag = values[index]
            index += 1
            if let key = options[flag] { try assign(key, value: take(flag)); continue }
            switch flag {
            case "--find", "--context", "--json", "--full", "--fold-yo", "--literal-space", "-f":
                guard seen.insert(flag).inserted else { throw SearchSupport.fail(Errors.CLI.duplicateOption(flag)) }
                switch flag {
                case "--find": find = true
                case "--context": context = true
                case "--json": json = true
                case "--full": request["full"] = true
                case "--fold-yo": request["fold_yo"] = true
                case "--literal-space": request["normalize_space"] = false
                default: compact = true
                }
            case "-i", "-e", "--eq", "--equal", "-ie", "-ei":
                if ["-i", "-ie", "-ei"].contains(flag) {
                    guard seen.insert("ignore_case").inserted else { throw SearchSupport.fail(Errors.CLI.duplicateOption(flag)) }
                    request["ignore_case"] = true
                }
                if flag != "-i" { try assign("match", value: "whole") }
            case "-s", "--search": try assign("search", value: take(flag))
            case "-r", "-w": base.append(flag)
            case "--db", "-db", "--config", "--timeout", "--where", "--order-by", "--sort", "-n":
                base += [flag, try take(flag)]
            case "-t", "--table", "-c", "--column":
                base.append(flag)
                let start = index
                while index < values.count, !values[index].hasPrefix("-") { base.append(values[index]); index += 1 }
                guard index > start else { throw SearchSupport.fail(Errors.CLI.valueRequired(flag)) }
            default: throw SearchSupport.fail(Errors.CLI.unknownArgument(flag))
            }
        }
        guard !(context && find) else { throw SearchSupport.fail(Errors.Search.cli) }
        var arguments = try Arguments(base, inShell: inShell)
        guard arguments.tableNames.count == 1, arguments.tableNames != ["*"], arguments.columnNames != ["*"] else { throw SearchSupport.fail(Errors.Search.cli) }
        request["table"] = arguments.tableNames[0]
        request[context ? "text_columns" : "search_columns"] = arguments.columnNames
        if !arguments.whereTexts.isEmpty { request["where"] = arguments.whereTexts }
        if !arguments.orderFields.isEmpty { request["order_by"] = arguments.orderFields }
        if let limit = arguments.rowLimit { request["limit"] = limit }
        let tool = context ? "read_context" : "search_rows"
        try SearchSchema.validate(request, tool: tool)
        arguments.searchCommand = Command(tool: tool, arguments: request, json: json, compact: compact)
        return arguments
    }

    static func run(_ command: Command, inspector: DatabaseInspector) throws {
        let result: [String: Any]
        if command.tool == "search_rows" { result = try Search.run(command.arguments, inspector: inspector) }
        else { result = try SearchContext.run(command.arguments, inspector: inspector) }
        if command.json {
            print(String(decoding: try SearchSupport.identity(result), as: UTF8.self))
            return
        }
        func literal(_ value: Any) -> String {
            (try? String(decoding: SearchSupport.identity(value), as: UTF8.self)) ?? "null"
        }
        func safe(_ text: String) -> String {
            text.unicodeScalars.map { scalar in
                if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" { return "\\u{\(String(scalar.value, radix: 16))}" }
                return String(scalar)
            }.joined()
        }
        print("TABLE: \(result["table"] ?? "")")
        for item in result["results"] as? [[String: Any]] ?? [] {
            print("\n--- Result \(item["position"] ?? 0) | key \(literal(item["key"] ?? [:])) ---")
            if let score = item["score"] { print("Score: \(score); span: \(item["span_rows"] ?? 1) eligible row(s)") }
            if let group = item["group"] as? [String: Any], !group.isEmpty { print("Group: \(literal(group))") }
            for proof in item["evidence"] as? [[String: Any]] ?? [] {
                print("Condition \(proof["condition"] ?? 0): \(literal(proof["query"] ?? "")) | \(literal(proof["field"] ?? "")) | key \(literal(proof["key"] ?? [:]))")
            }
            let messages = item["messages"] as? [[String: Any]] ?? [item]
            for message in messages {
                print("Key: \(literal(message["key"] ?? [:]))")
                if let metadata = message["metadata"] { print("Metadata: \(literal(metadata))") }
                if let time = message["time"] { print("Time: \(literal(time))") }
                if let relative = message["relative_position"] { print("Relative position: \(relative)") }
                for (path, raw) in (message["snippets"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    guard let snippet = raw as? [String: Any], let text = snippet["text"] as? String else { continue }
                    let clipped = snippet["truncated_before"] as? Bool == true || snippet["truncated_after"] as? Bool == true
                    let display = command.compact ? String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ") : text
                    print("\(literal(path)) [\(snippet["start"] ?? 0)..<\(snippet["end"] ?? 0)]\(clipped ? " (excerpt)" : ""):")
                    print(safe(display) + (command.compact && text.count > 120 ? "…" : ""))
                }
            }
        }
        print("\nResults: \(result["row_count"] ?? 0); more: \(result["has_more"] as? Bool ?? false); next offset: \(result["next_offset"] ?? NSNull())")
        if result["budget_reached"] as? Bool == true { print("Output budget reached; continue with --offset or increase --max-bytes.") }
        if result["offset_limit_reached"] as? Bool == true { print("Offset limit reached; narrow --where filters.") }
    }
}
