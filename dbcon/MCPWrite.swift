//
//  MCPWrite.swift
//  dbcon
//
//  Created by SITIS on 11/13/26.
//

import Foundation

extension MCP {
    static var writeTools: [[String: Any]] {
        func strings(_ description: String) -> [String: Any] {
            ["type": "array", "items": ["type": "string", "minLength": 1], "minItems": 1, "description": description]
        }
        let table: [String: Any] = ["type": "string", "minLength": 1, "description": "One existing literal table name."]
        let columns = strings("Existing literal columns, no duplicates or '*'. Omit insert columns to use table order.")
        let values = strings("Rows as SQL expression lists, one string per row, without enclosing parentheses. Example: [\"1, 'Alice', 35\", \"2, 'Bob', NULL\"]. Quote SQL text with single quotes; double embedded single quotes. SQL expressions, not raw text values.")
        let assignments: [String: Any] = ["type": "string", "minLength": 1, "description": "SQL assignments, e.g. age = age + 1, name = 'Alice'. SQL expressions, not raw text values."]
        let filter = strings("Same restricted filters as read_rows; multiple entries use AND. Required for update/delete unless all_rows is true.")
        let all: [String: Any] = ["type": "boolean", "description": "Explicitly modify every row. Cannot be combined with where."]
        let returning = strings("Optional existing literal columns to return with SQLite RETURNING. Omit for counters only. May return many complete values; SQLite RETURNING rules apply.")
        let shared: [String: Any] = ["table": table, "returning": returning]
        var insert = shared
        insert["columns"] = columns
        insert["values"] = values
        var update = shared
        update["set"] = assignments
        update["where"] = filter
        update["all_rows"] = all
        var delete = shared
        delete["where"] = filter
        delete["all_rows"] = all
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false]]
        }
        var operation = shared
        operation["action"] = ["type": "string", "enum": ["insert", "update", "delete"]]
        operation["columns"] = columns
        operation["values"] = values
        operation["set"] = assignments
        operation["where"] = filter
        operation["all_rows"] = all
        let operations: [String: Any] = ["type": "array", "minItems": 1,
            "items": ["type": "object", "properties": operation, "required": ["action", "table"], "additionalProperties": false],
            "description": "Ordered insert/update/delete operations, possibly on different tables in this database. Insert requires values; update requires set. Update/delete require where or all_rows: true. One atomic transaction for the entire array."]
        return [
            tool("insert_rows", "Insert one or more rows atomically. Commits on success; rolls back the entire call on error. Returns counters, plus explicitly requested returning fields.", insert, ["table", "values"]),
            tool("update_rows", "Update matching rows atomically. Requires where or explicit all_rows: true. Commits on success, rolls back on error.", update, ["table", "set"]),
            tool("delete_rows", "Delete matching rows atomically. Requires where or explicit all_rows: true. Commits on success, rolls back on error.", delete, ["table"]),
            tool("write_batch", "Execute ordered mixed writes in one atomic transaction. Any failure rolls back the entire call. No SAVE/CANCEL; do not retry blindly after a lost response.", ["operations": operations], ["operations"])
        ]
    }

    static func performWrite(_ name: String, arguments: [String: Any], inspector: DatabaseInspector) throws -> [String: Any] {
        try inspector.requireWriteAccess()
        guard !inspector.hasTransaction else { throw Arguments.ArgumentError.invalid(Errors.RPC.pendingTransaction) }
        let operations: [[String: Any]]
        if name == "write_batch" {
            guard let entries = arguments["operations"] as? [[String: Any]], !entries.isEmpty else {
                throw Arguments.ArgumentError.invalid(Errors.RPC.writeBatch)
            }
            operations = entries
        } else {
            var operation = arguments
            operation["action"] = ["insert_rows": "insert", "update_rows": "update", "delete_rows": "delete"][name]
            operations = [operation]
        }
        var index = 0
        do {
            try inspector.beginChanges(mode: "IMMEDIATE")
            var results: [[String: Any]] = []
            for (offset, operation) in operations.enumerated() {
                index = offset + 1
                let prepared = try prepareWrite(operation, inspector: inspector)
                var result = try inspector.executeMCPStatement(prepared.sql, parameters: prepared.parameters)
                result["operation"] = index
                result["action"] = operation["action"]
                result["table"] = operation["table"]
                results.append(result)
            }
            try inspector.commitMCPChanges()
            return ["committed": true, "operation_count": results.count, "operations": results]
        } catch {
            let detail = error.localizedDescription
            do { try inspector.rollbackMCPChanges() }
            catch {
                throw Arguments.ArgumentError.invalid(Errors.RPC.batchFailure(index, detail: detail, rollback: Errors.RPC.rollbackFailed(error.localizedDescription)))
            }
            throw Arguments.ArgumentError.invalid(Errors.RPC.batchFailure(index, detail: detail, rollback: Errors.RPC.batchRolledBack))
        }
    }

    private static func prepareWrite(_ operation: [String: Any], inspector: DatabaseInspector) throws -> (sql: String, parameters: [SQLValue]) {
        guard let action = operation["action"] as? String,
              let tool = writeTools.first(where: { $0["name"] as? String == action + "_rows" }),
              let schema = tool["inputSchema"] as? [String: Any] else {
            throw Arguments.ArgumentError.invalid(Errors.RPC.writeShape)
        }
        var arguments = operation
        arguments.removeValue(forKey: "action")
        try validate(arguments, schema: schema)
        let table = arguments["table"] as? String ?? ""
        guard try inspector.tableNames().contains(table) else {
            throw Arguments.ArgumentError.invalid(Errors.RPC.missingTable(table))
        }
        let available = try inspector.columnNames(table)
        func fields(_ key: String) throws -> [String]? {
            guard let names = arguments[key] as? [String] else { return nil }
            guard !names.isEmpty, Set(names).count == names.count, names.allSatisfy({ $0 != "*" && available.contains($0) }) else {
                throw Arguments.ArgumentError.invalid(Errors.RPC.writeColumns)
            }
            return names.map(QuerySQL.quote)
        }
        let returning = try fields("returning")
        let target = QuerySQL.quote(table)
        var sql: String
        var parameters: [SQLValue] = []
        if action == "insert" {
            let columns = try fields("columns")
            let projection = columns.map { " (" + $0.joined(separator: ", ") + ")" } ?? ""
            let values = arguments["values"] as? [String] ?? []
            sql = "INSERT INTO \(target)\(projection) VALUES " + values.map { "(" + $0 + ")" }.joined(separator: ", ")
        } else {
            let conditions = arguments["where"] as? [String] ?? []
            let all = arguments["all_rows"] as? Bool ?? false
            let filtered = !conditions.isEmpty
            guard all != filtered else {
                throw Arguments.ArgumentError.invalid(Errors.RPC.writeShape)
            }
            let query = try QuerySQL(columns: ["*"], available: available, terms: [], conditions: conditions, orderFields: [], ignoreCase: false, exact: false)
            parameters = query.parameters
            if action == "update" {
                sql = "UPDATE \(target) SET \(arguments["set"] as? String ?? "") WHERE \(query.filter)"
            } else {
                sql = "DELETE FROM \(target) WHERE \(query.filter)"
            }
        }
        if let returning { sql += " RETURNING " + returning.joined(separator: ", ") }
        return (sql, parameters)
    }
}
