//
//  SearchContext.swift
//  dbcon
//
//  Created by SITIS on 11/16/26.
//

import Foundation
import SQLite3

enum SearchContext {
    static func run(_ arguments: [String: Any], inspector: DatabaseInspector) throws -> [String: Any] {
        try SearchSchema.validate(arguments, tool: "read_context")
        return try SearchSupport.snapshot(inspector) { try perform(arguments, inspector: inspector) }
    }

    private static func perform(_ a: [String: Any], inspector: DatabaseInspector) throws -> [String: Any] {
        let table = a["table"] as? String ?? ""
        let available = try SearchSupport.columns(table, inspector: inspector)
        let keys = a["key_columns"] as? [String] ?? []
        let columns = a["text_columns"] as? [String] ?? []
        let metadata = a["metadata_columns"] as? [String] ?? []
        let conditions = a["where"] as? [String] ?? []
        let anchorConditions = a["anchor_where"] as? [String] ?? []
        let order = a["order_by"] as? [String] ?? []
        let before = (a["before"] as? NSNumber)?.intValue ?? 2
        let after = (a["after"] as? NSNumber)?.intValue ?? 2
        let limit = (a["limit"] as? NSNumber)?.intValue ?? 10
        let offset = (a["offset"] as? NSNumber)?.intValue ?? 0
        let size = (a["snippet_chars"] as? NSNumber)?.intValue ?? 240
        let maximum = (a["max_bytes"] as? NSNumber)?.intValue ?? 16000
        let sourceField = a["source_field"] as? String
        let relatedField = a["related_field"] as? String
        let related = sourceField != nil || relatedField != nil || a["source_table"] != nil
        guard !anchorConditions.isEmpty else { throw SearchSupport.fail(Errors.Search.anchor) }
        guard !columns.isEmpty, Set(columns).count == columns.count, !columns.contains("*") else { throw SearchSupport.fail(Errors.Search.fields) }
        try SearchSupport.fields(metadata, available: available)
        try SearchSupport.keys(keys, table: table, available: available, inspector: inspector)
        try SearchSupport.validateTime(a, available: available)
        let timeFields = (a["time_column"] as? String).map { [$0] } ?? []
        let fields = Array(Set(keys + columns + metadata + timeFields)).sorted()
        let projection = try SearchFields.projection(fields, available: available)
        let query = try QuerySQL(columns: keys, available: available, terms: [], conditions: conditions, orderFields: order + keys.map { "\($0) ASC" }, ignoreCase: false, exact: false)
        var rows: [(row: [String: Any], values: [SearchFields.Value], position: Int)] = []
        var anchor: [String: Any]
        var anchorPosition: Int?
        var targetFilter = query.filter
        var parameters = query.parameters
        var anchorKey: Data?
        if related {
            guard let sourceField, let relatedField, a["before"] == nil, a["after"] == nil else { throw SearchSupport.fail(Errors.Search.relation) }
            let sourceTable = a["source_table"] as? String ?? table
            let sourceColumns = try SearchSupport.columns(sourceTable, inspector: inspector)
            try SearchSupport.fields([sourceField], available: sourceColumns, required: true)
            let expression = try QuerySQL.expression(relatedField, available: available)
            let sourceQuery = try QuerySQL(columns: [sourceField], available: sourceColumns, terms: [], conditions: anchorConditions, orderFields: [], ignoreCase: false, exact: false)
            let sourceRows = try inspector.structuredRows("SELECT \(sourceQuery.projection) FROM \(QuerySQL.quote(sourceTable)) WHERE \(sourceQuery.filter) LIMIT 2", parameters: sourceQuery.parameters)
            guard sourceRows.count == 1 else { throw SearchSupport.fail(Errors.Search.anchor) }
            let value = sourceRows[0][sourceField] ?? NSNull()
            let scalar = try SearchSupport.scalar(value)
            anchor = ["table": sourceTable, "field": sourceField, "value": value]
            targetFilter = "(\(query.filter)) AND \(expression) = ?"
            parameters.append(scalar)
        } else {
            guard !order.isEmpty else { throw SearchSupport.fail(Errors.Search.order) }
            let anchorQuery = try QuerySQL(columns: keys, available: available, terms: [], conditions: conditions + anchorConditions, orderFields: [], ignoreCase: false, exact: false)
            let anchors = try inspector.structuredRows("SELECT \(anchorQuery.projection) FROM \(QuerySQL.quote(table)) WHERE \(anchorQuery.filter) LIMIT 2", parameters: anchorQuery.parameters)
            guard anchors.count == 1 else { throw SearchSupport.fail(Errors.Search.anchor) }
            anchor = ["table": table, "key": anchors[0]]
            anchorKey = try SearchSupport.identity(anchors[0])
        }
        var position = 0
        var previous: [(row: [String: Any], values: [SearchFields.Value], position: Int)] = []
        try SearchSupport.stream("SELECT \(projection) FROM \(QuerySQL.quote(table)) WHERE \(targetFilter)\(query.orderClause)", parameters: parameters, inspector: inspector) { row in
            let values = try SearchFields.values(columns, row: row, elementTypes: a["element_types"] as? [String] ?? [], typeField: a["element_type_field"] as? String ?? "type", literalFields: available)
            guard !values.isEmpty else { return }
            position += 1
            let item = (row: row, values: values, position: position)
            if related {
                if position > offset && rows.count <= limit { rows.append(item) }
            } else if try SearchSupport.identity(SearchSupport.selected(keys, row: row)) == anchorKey {
                anchorPosition = position
                rows = previous + [item]
            } else if let anchorPosition {
                if position <= anchorPosition + after { rows.append(item) }
            } else {
                previous.append(item)
                if previous.count > before { previous.removeFirst() }
            }
        }
        if !related {
            guard let anchorPosition else { throw SearchSupport.fail(Errors.Search.anchor) }
            anchor["position"] = anchorPosition
            rows = Array(rows.dropFirst(offset).prefix(limit + 1))
        }
        let more = rows.count > limit
        if more { rows.removeLast() }
        let results = try rows.enumerated().map { index, item -> [String: Any] in
            let row = item.row
            let key = SearchSupport.selected(keys, row: row)
            for value in key.values { _ = try SearchSupport.scalar(value) }
            var snippets: [String: Any] = [:]
            for value in item.values {
                let text = SearchText(value.text, options: SearchText.Options())
                snippets[value.path] = text.snippet(around: nil, characters: a["full"] as? Bool == true ? max(1, text.original.count) : size)
            }
            var output: [String: Any] = ["key": key, "position": offset + index + 1, "snippets": snippets]
            if let anchorPosition { output["relative_position"] = item.position - anchorPosition }
            if !metadata.isEmpty { output["metadata"] = SearchSupport.selected(metadata, row: row) }
            if let time = try SearchSupport.time(a, row: row) { output["time"] = time }
            return output
        }
        return try SearchSupport.bounded([
            "table": table, "mode": related ? "related" : "neighbors", "anchor": anchor,
            "limit": limit, "offset": offset
        ], candidates: results, maximum: maximum, offset: offset, more: more)
    }
}

enum SearchSupport {
    static func fail(_ message: String) -> Arguments.ArgumentError { .invalid(message) }

    static func fields(_ fields: [String], available: [String], required: Bool = false) throws {
        guard (!required || !fields.isEmpty), Set(fields).count == fields.count, !fields.contains("*") else { throw fail(Errors.Search.fields) }
        for field in fields { _ = try QuerySQL.expression(field, available: available) }
    }

    static func columns(_ table: String, inspector: DatabaseInspector) throws -> [String] {
        guard try inspector.tableNames().contains(table) else { throw fail(Errors.RPC.missingTable(table)) }
        return try inspector.columnNames(table)
    }

    static func keys(_ columns: [String], table: String, available: [String], inspector: DatabaseInspector) throws {
        guard !columns.isEmpty, Set(columns).count == columns.count, columns.allSatisfy(available.contains) else { throw fail(Errors.Search.keys) }
        let names = columns.map(QuerySQL.quote).joined(separator: ", ")
        let nulls = columns.map { "\(QuerySQL.quote($0)) IS NULL" }.joined(separator: " OR ")
        let source = QuerySQL.quote(table)
        guard try inspector.structuredRows("SELECT 1 FROM \(source) WHERE \(nulls) LIMIT 1").isEmpty,
              try inspector.structuredRows("SELECT 1 FROM \(source) GROUP BY \(names) HAVING count(*) > 1 LIMIT 1").isEmpty else { throw fail(Errors.Search.keys) }
    }

    static func stream(_ sql: String, parameters: [SQLValue], inspector: DatabaseInspector, body: ([String: Any]) throws -> Void) throws {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(inspector.database, sql, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard status == SQLITE_OK, let statement else { throw inspector.sqliteError(Errors.Database.preparingSearch) }
        try inspector.bind(parameters, to: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(DatabaseInspector.structuredRow(statement))
            case SQLITE_DONE: return
            default: throw inspector.sqliteError(Errors.Database.preparingSearch)
            }
        }
    }

    static func snapshot<T>(_ inspector: DatabaseInspector, body: () throws -> T) throws -> T {
        let own = sqlite3_get_autocommit(inspector.database) != 0
        if own, sqlite3_exec(inspector.database, "BEGIN", nil, nil, nil) != SQLITE_OK { throw inspector.sqliteError(Errors.Database.preparingSearch) }
        do {
            let result = try body()
            if own, sqlite3_exec(inspector.database, "COMMIT", nil, nil, nil) != SQLITE_OK { throw inspector.sqliteError(Errors.Database.preparingSearch) }
            return result
        } catch {
            if own { sqlite3_exec(inspector.database, "ROLLBACK", nil, nil, nil) }
            throw error
        }
    }

    static func selected(_ fields: [String], row: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0, row[$0] ?? NSNull()) })
    }

    static func identity(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func scalar(_ value: Any) throws -> SQLValue {
        if let text = value as? String { return .text(text) }
        if let number = value as? NSNumber, number.doubleValue.isFinite {
            if String(cString: number.objCType) == "d" || String(cString: number.objCType) == "f" { return .real(number.doubleValue) }
            return .integer(number.int64Value)
        }
        throw fail(Errors.Search.scalar)
    }

    static func validateTime(_ arguments: [String: Any], available: [String]) throws {
        if let field = arguments["time_column"] as? String {
            _ = try QuerySQL.expression(field, available: available)
            guard arguments["time_unit"] != nil, TimeZone(identifier: arguments["time_zone"] as? String ?? "UTC") != nil else { throw fail(Errors.Search.timestamp) }
        } else if arguments["time_unit"] != nil || arguments["time_zone"] != nil { throw fail(Errors.Search.timestamp) }
    }

    static func time(_ arguments: [String: Any], row: [String: Any]) throws -> [String: Any]? {
        guard let field = arguments["time_column"] as? String else { return nil }
        let raw = row[field] ?? NSNull()
        let zone = arguments["time_zone"] as? String ?? "UTC"
        if raw is NSNull { return ["field": field, "raw": raw, "formatted": NSNull(), "time_zone": zone] }
        let unit = arguments["time_unit"] as? String ?? ""
        let date: Date?
        if unit == "iso8601", let text = raw as? String {
            let parser = ISO8601DateFormatter()
            guard text.range(of: "(?:[zZ]|[+-][0-9]{2}:?[0-9]{2})$", options: .regularExpression) != nil, text.contains("T") else { throw fail(Errors.Search.invalidTime) }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        } else if unit != "iso8601", let number = raw as? NSNumber, number.doubleValue.isFinite {
            let seconds = number.doubleValue / (unit == "milliseconds" ? 1000 : 1)
            date = abs(seconds) <= 253402300799 ? Date(timeIntervalSince1970: seconds) : nil
        } else { date = nil }
        guard let date else { throw fail(Errors.Search.invalidTime) }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["field": field, "raw": raw, "formatted": formatter.string(from: date), "time_zone": zone]
    }

    static func bounded(_ base: [String: Any], candidates: [[String: Any]], maximum: Int, offset: Int = 0, more: Bool) throws -> [String: Any] {
        var rows: [[String: Any]] = []
        func response(_ rows: [[String: Any]], budget: Bool) -> [String: Any] {
            var value = base
            let hasMore = more || rows.count < candidates.count
            let offsetLimit = hasMore && offset + rows.count > 10000
            value["results"] = rows
            value["row_count"] = rows.count
            value["has_more"] = hasMore
            value["next_offset"] = hasMore && !offsetLimit ? (offset + rows.count) as Any : NSNull()
            value["offset_limit_reached"] = offsetLimit
            value["budget_reached"] = budget
            value["max_bytes"] = maximum
            return value
        }
        for row in candidates {
            if try identity(response(rows + [row], budget: false)).count > maximum {
                if rows.isEmpty { throw fail(Errors.Search.budget) }
                return response(rows, budget: true)
            }
            rows.append(row)
        }
        let result = response(rows, budget: false)
        guard try identity(result).count <= maximum else { throw fail(Errors.Search.budget) }
        return result
    }
}
