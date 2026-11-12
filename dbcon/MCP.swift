//
//  MCP.swift
//  dbcon
//
//  Created by SITIS on 11/12/26.
//

import CoreFoundation
import Foundation

enum MCP {
    private struct RPCError: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }

    static func run(inspector: DatabaseInspector) throws {
        let session = Session(inspector: inspector)
        while let line = readLine() {
            try session.receive(Data(line.utf8))
        }
    }

    private final class Session {
        let inspector: DatabaseInspector
        var initializationSent = false
        var initialized = false

        init(inspector: DatabaseInspector) {
            self.inspector = inspector
        }

        func receive(_ data: Data) throws {
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            } catch {
                try failure(id: NSNull(), code: -32700, message: "Parse error: expected one JSON message per line.")
                return
            }
            guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0" else {
                try failure(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request.")
                return
            }
            if request["method"] == nil, request["result"] != nil || request["error"] != nil {
                return
            }
            guard let method = request["method"] as? String,
                  request["id"] == nil || validID(request["id"]!) else {
                try failure(id: NSNull(), code: -32600, message: "Invalid method or request ID.")
                return
            }
            guard let id = request["id"] else {
                if method == "notifications/initialized", initializationSent,
                   request["params"] == nil || request["params"] is [String: Any] {
                    initialized = true
                }
                return
            }
            do {
                if let params = request["params"], !(params is [String: Any]) {
                    throw RPCError(code: -32602, message: "params must be an object.")
                }
                let params = request["params"] as? [String: Any] ?? [:]
                let result = try dispatch(method, params: params)
                try send(["jsonrpc": "2.0", "id": id, "result": result])
            } catch let error as RPCError {
                try failure(id: id, code: error.code, message: error.message)
            }
        }

        func dispatch(_ method: String, params: [String: Any]) throws -> [String: Any] {
            if method == "ping" { return [:] }
            if method == "initialize" {
                guard !initializationSent else {
                    throw RPCError(code: -32600, message: "This connection is already initialized.")
                }
                guard let version = params["protocolVersion"] as? String, !version.isEmpty,
                      params["capabilities"] is [String: Any],
                      let client = params["clientInfo"] as? [String: Any],
                      client["name"] is String, client["version"] is String else {
                    throw RPCError(code: -32602, message: "initialize requires protocolVersion, capabilities, and clientInfo.")
                }
                initializationSent = true
                return [
                    "protocolVersion": "2025-06-18",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "dbcon", "version": "1.0.0"],
                    "instructions": "Read-only SQLite tools. Discover tables and columns before querying unfamiliar databases. Use small limits and select needed columns. Read chronological batches with order_by and where; use a unique tie-breaker after timestamps. Search is literal, not semantic: try synonyms in separate calls. Values are complete, timestamps are not converted, and JSON fields use column:$.path."
                ]
            }
            guard initialized else {
                throw RPCError(code: -32000, message: "Send initialize and notifications/initialized before using tools.")
            }
            switch method {
            case "tools/list":
                guard Set(params.keys).isSubset(of: ["_meta"]),
                      params["_meta"] == nil || params["_meta"] is [String: Any] else {
                    throw RPCError(code: -32602, message: "tools/list accepts only optional _meta; all tools fit on one page.")
                }
                return ["tools": MCP.tools]
            case "tools/call":
                guard let name = params["name"] as? String,
                      let tool = MCP.tools.first(where: { $0["name"] as? String == name }),
                      let schema = tool["inputSchema"] as? [String: Any] else {
                    throw RPCError(code: -32602, message: "Unknown or missing tool name.")
                }
                if let arguments = params["arguments"], !(arguments is [String: Any]) {
                    throw RPCError(code: -32602, message: "arguments must be an object.")
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                try MCP.validate(arguments, schema: schema)
                do {
                    let result = try query(name, arguments: arguments)
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    return [
                        "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                        "structuredContent": result,
                        "isError": false
                    ]
                } catch {
                    return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
                }
            default:
                throw RPCError(code: -32601, message: "Method not found: \(method).")
            }
        }

        func query(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
            if name == "list_tables" { return ["tables": try inspector.tableNames()] }
            let table = arguments["table"] as? String ?? ""
            guard try inspector.tableNames().contains(table) else {
                throw Arguments.ArgumentError.invalid("Table '\(table)' does not exist. Use list_tables first.")
            }
            let identifier = QuerySQL.quote(table)
            if name == "describe_table" {
                return [
                    "table": table,
                    "columns": try inspector.structuredRows("PRAGMA table_info(\(identifier))"),
                    "definition": try inspector.structuredRows("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", parameters: [.text(table)])
                ]
            }
            let columns = arguments["columns"] as? [String] ?? ["*"]
            let search = arguments["search"] as? [String] ?? []
            let conditions = arguments["where"] as? [String] ?? []
            let order = arguments["order_by"] as? [String] ?? []
            let ignoreCase = arguments["ignore_case"] as? Bool ?? false
            let exact = arguments["exact"] as? Bool ?? false
            let nonEmpty = arguments["non_empty"] as? Bool ?? false
            guard !search.isEmpty || (!ignoreCase && !exact) else {
                throw Arguments.ArgumentError.invalid("ignore_case and exact require a nonempty search array.")
            }
            if !search.isEmpty { try inspector.registerSearch() }
            let available = try inspector.columnNames(table)
            let query = try QuerySQL(columns: columns, available: available, terms: search, conditions: conditions, orderFields: order, ignoreCase: ignoreCase, exact: exact)
            if name == "count_rows" {
                guard arguments["columns"] == nil || nonEmpty || !search.isEmpty else {
                    throw Arguments.ArgumentError.invalid("columns with count_rows requires non_empty or search.")
                }
                let filled = nonEmpty ? try QuerySQL.nonEmptyFilter(columns: columns, available: available) : ""
                let rows = try inspector.structuredRows("SELECT COUNT(*) AS rows FROM \(identifier) WHERE \(query.filter)\(filled)", parameters: query.parameters)
                return ["table": table, "rows": rows.first?["rows"] ?? 0]
            }
            let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 100
            let rows = try inspector.structuredRows("SELECT \(query.projection) FROM \(identifier) WHERE \(query.filter)\(query.orderClause) LIMIT \(limit)", parameters: query.parameters)
            return ["table": table, "rows": rows, "row_count": rows.count, "limit": limit, "limit_reached": rows.count == limit]
        }

        func validID(_ value: Any) -> Bool {
            if value is String { return true }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
        }

        func failure(id: Any, code: Int, message: String) throws {
            try send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    private static func validate(_ arguments: [String: Any], schema: [String: Any]) throws {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = schema["required"] as? [String] ?? []
        guard Set(arguments.keys).isSubset(of: Set(properties.keys)), required.allSatisfy({ arguments[$0] != nil }) else {
            throw RPCError(code: -32602, message: "Unknown or missing arguments. Allowed: \(properties.keys.sorted().joined(separator: ", ")); required: \(required.joined(separator: ", ")).")
        }
        for (key, value) in arguments {
            let property = properties[key] ?? [:]
            var valid = false
            switch property["type"] as? String {
            case "string":
                if let text = value as? String { valid = validText(text) }
            case "array":
                if let values = value as? [String] {
                    valid = values.allSatisfy(validText)
                    if let minimum = property["minItems"] as? Int { valid = valid && values.count >= minimum }
                    if property["uniqueItems"] as? Bool == true { valid = valid && Set(values).count == values.count }
                }
            case "boolean":
                if let number = value as? NSNumber { valid = CFGetTypeID(number) == CFBooleanGetTypeID() }
            case "integer":
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    valid = number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
                        && number.compare(NSNumber(value: 1)) != .orderedAscending
                        && number.compare(NSNumber(value: Int.max)) != .orderedDescending
                }
            default: break
            }
            guard valid else { throw RPCError(code: -32602, message: "Invalid argument '\(key)'. Expected \(property["type"] as? String ?? "a valid value").") }
        }
    }

    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains("\0")
    }

    private static var tools: [[String: Any]] {
        let table: [String: Any] = ["type": "string", "minLength": 1, "description": "One literal table name from list_tables; no wildcard."]
        func strings(_ description: String) -> [String: Any] {
            ["type": "array", "items": ["type": "string", "minLength": 1], "description": description]
        }
        var columns = strings("Output fields; also fields checked by plain-text search or non_empty. Default: all. JSON: data:$.text. Use '*' alone.")
        columns["minItems"] = 1
        columns["uniqueItems"] = true
        var common: [String: Any] = [
            "table": table,
            "columns": columns,
            "search": strings("AND conditions. Each is a literal substring or field=value. A plain term checks any selected column. Use separate calls for synonyms (OR)."),
            "where": strings("AND filters. Each supports AND/OR, parentheses, = != <> > >= < <= IS NULL IS NOT NULL. Quote text values with SQL quotes; numbers stay numeric. No arbitrary SQL."),
            "ignore_case": ["type": "boolean", "default": false, "description": "Unicode case-insensitive search; requires search."],
            "exact": ["type": "boolean", "default": false, "description": "Whole-value matching for every search condition; requires search."]
        ]
        var read = common
        read["order_by"] = strings("Sort fields, e.g. ['time_created ASC', 'id ASC']. Default ASC. Add a unique tie-breaker for stable batches.")
        read["limit"] = ["type": "integer", "minimum": 1, "maximum": Int.max, "default": 100, "description": "Maximum rows returned. Does not truncate individual field values."]
        common["non_empty"] = ["type": "boolean", "default": false, "description": "Count rows with at least one nonempty selected value, using CLI -p rules."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
            [
                "name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
            ]
        }
        return [
            tool("list_tables", "List tables in the connected SQLite database.", [:], required: []),
            tool("describe_table", "Get column structure and CREATE TABLE definition without reading records.", ["table": table], required: ["table"]),
            tool("read_rows", "Read or search one table. Returns typed JSON with complete field values. Default limit 100. limit_reached means more rows may exist; continue with where and order_by.", read, required: ["table"]),
            tool("count_rows", "Count matching rows, optionally checking nonempty values. Does not return records or accept limit/order_by.", common, required: ["table"])
        ]
    }
}
