//
//  DatabaseInspector.swift
//  dbcon
//
//  Created by SITIS on 11/10/26.
//

import Darwin
import Foundation
import SQLite3

final class DatabaseInspector {
    enum Mode: String, Codable {
        case schema
        case full
    }

    let database: OpaquePointer
    let databasePath: String
    let readOnly: Bool
    var checkingUserSQL = false
    var allowsMaintenance = false
    var sqlTransaction = false
    var sqlDenial: String?

    init(databasePath: String, readOnly: Bool, busyTimeoutMilliseconds: Int32) throws {
        self.databasePath = databasePath
        self.readOnly = readOnly
        var connection: OpaquePointer?

        let result = sqlite3_open_v2(
            databasePath,
            &connection,
            (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard result == SQLITE_OK, let connection else {
            let error = Errors.sqliteFailure(operation: Errors.Database.opening, path: databasePath, database: connection, result: result)
            if let connection {
                sqlite3_close(connection)
            }
            throw error
        }

        guard busyTimeoutMilliseconds >= 1000 else {
            sqlite3_close(connection)
            throw InspectionError.sqlite(
                operation: Errors.Database.timeout,
                message: Errors.Database.timeoutMinimum
            )
        }

        let timeoutResult = sqlite3_busy_timeout(connection, busyTimeoutMilliseconds)
        guard timeoutResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection)
            throw InspectionError.sqlite(operation: Errors.Database.timeout, message: message)
        }

        database = connection
    }

    deinit {
        sqlite3_close(database)
    }

    func inspect(mode: Mode) throws {
        print("DATABASE: \(databasePath)")
        print("SQLite: \(String(cString: sqlite3_libversion()))")
        print("Mode: \(readOnly ? "read-only" : "read-write")")
        print("Inspection: \(mode.rawValue)")

        var tables: [(name: String, definition: String)] = []
        try forEachRow("SELECT name, sql FROM sqlite_schema WHERE type = 'table' ORDER BY name") {
            statement in
            tables.append((
                name: Self.text(statement, column: 0),
                definition: Self.text(statement, column: 1)
            ))
        }

        print("\nTABLES: \(tables.count)")
        for table in tables {
            print("- \(table.name)")
        }

        for table in tables {
            print("\n========== TABLE: \(table.name) ==========")
            print("\nSQL DEFINITION:\n\(table.definition)")

            let identifier = Self.quotedIdentifier(table.name)
            print("\nCOLUMNS (cid, name, type, notnull, dflt_value, pk):")
            try forEachRow("PRAGMA table_info(\(identifier))") { statement in
                let fields = (0..<sqlite3_column_count(statement)).map { column in
                    Self.value(statement, column: column)
                }
                print(fields.joined(separator: " | "))
            }

            if mode == .full {
                print("\nCONTENTS:")
                try dumpRows("SELECT * FROM \(identifier)")
            }
        }

        print("\n========== INSPECTION COMPLETE ==========")
    }

    func listTables() throws {
        let names = try tableNames()
        print("TABLES: \(names.count)")
        for name in names {
            print(name)
        }
    }

    func showColumns(tables: [String]) throws {
        for table in try selectedTables(tables) {
            print("\nTABLE: \(table)")
            let headers = ["cid", "name", "type", "notnull", "dflt_value", "pk"]
            var rows: [[String]] = []
            try forEachRow("PRAGMA table_info(\(Self.quotedIdentifier(table)))") { statement in
                let fields = (0..<sqlite3_column_count(statement)).map { column in
                    Self.value(statement, column: column)
                }
                rows.append(fields)
            }
            let screen = terminalColumns()
            let allocated = compactWidths(headers: headers, rows: rows, screen: screen)
            let widths = headers.indices.map { index in
                min(allocated[index], max(headers[index].count, rows.map { $0[index].count }.max() ?? 0))
            }
            print(formatCompact(headers.indices.map { clip(headers[$0], width: widths[$0]) }, widths: widths))
            print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
            for row in rows {
                print(formatCompact(row.indices.map { clip(row[$0], width: widths[$0]) }, widths: widths))
            }
        }
    }

    func readTables(tables: [String], columns: [String], conditions: [String] = [], orderFields: [String] = [], compact: Bool = false, rowLimit: Int? = nil) throws {
        for table in try selectedTables(tables) {
            let query = try QuerySQL(columns: columns, available: columnNames(table), terms: [], conditions: conditions, orderFields: orderFields, ignoreCase: false, exact: false)
            print("\nTABLE: \(table)")
            try dumpRows("SELECT \(query.projection) FROM \(Self.quotedIdentifier(table)) WHERE \(query.filter)\(query.orderClause)\(Self.limitClause(rowLimit))", compact: compact, parameters: query.parameters)
        }
    }

    func countRows(tables: [String], columns: [String], nonEmpty: Bool, queries: [String] = [], conditions: [String] = [], ignoreCase: Bool = false, exact: Bool = false) throws {
        if !queries.isEmpty { try registerSearch() }
        var rows: [[String]] = []
        for table in try selectedTables(tables) {
            let available = try columnNames(table)
            let query = try QuerySQL(columns: columns, available: available, terms: queries, conditions: conditions, orderFields: [], ignoreCase: ignoreCase, exact: exact)
            let filled = nonEmpty ? try QuerySQL.nonEmptyFilter(columns: columns, available: available) : ""
            try forEachRow("SELECT COUNT(*) FROM \(Self.quotedIdentifier(table)) WHERE \(query.filter)\(filled)", parameters: query.parameters) { statement in
                rows.append([table, Self.value(statement, column: 0)])
            }
        }
        let headers = ["table", "rows"]
        let widths = headers.indices.map { index in
            max(headers[index].count, rows.map { $0[index].count }.max() ?? 0)
        }
        print(formatCompact(headers, widths: widths))
        print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        for row in rows { print(formatCompact(row, widths: widths)) }
    }

    func columnNames(_ table: String) throws -> [String] {
        var names: [String] = []
        try forEachRow("PRAGMA table_info(\(Self.quotedIdentifier(table)))") { statement in
            names.append(Self.text(statement, column: 1))
        }
        return names
    }

    func tableNames() throws -> [String] {
        var names: [String] = []
        try forEachRow("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name") { statement in
            names.append(Self.text(statement, column: 0))
        }
        return names
    }

    func selectedTables(_ requested: [String]) throws -> [String] {
        let available = try tableNames()
        if requested == ["*"] {
            return available
        }
        guard !requested.isEmpty else {
            throw InspectionError.sqlite(operation: Errors.Database.selectingTables, message: Errors.Database.tablesRequired)
        }
        for table in requested where !available.contains(table) {
            throw InspectionError.sqlite(operation: Errors.Database.selectingTables, message: Errors.Database.missingTable(table))
        }
        return requested
    }

    func dumpRows(_ sql: String, compact: Bool = false, parameters: [SQLValue] = []) throws {
        if compact {
            try dumpCompact(sql, parameters: parameters)
            return
        }
        var rowNumber = 0
        try forEachRow(sql, parameters: parameters) { statement in
            rowNumber += 1
            print("\n--- Row \(rowNumber) ---")

            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                print("\(name):")
                print(Self.value(statement, column: column))
            }
        }
        print("\nTotal rows read: \(rowNumber)")
    }

    private func dumpCompact(_ sql: String, parameters: [SQLValue] = []) throws {
        var preparedStatement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &preparedStatement, nil)
        defer {
            if let preparedStatement {
                sqlite3_finalize(preparedStatement)
            }
        }
        guard result == SQLITE_OK, let preparedStatement else {
            throw sqliteError(Errors.Database.preparingQuery(sql))
        }
        try bind(parameters, to: preparedStatement)
        let count = Int(sqlite3_column_count(preparedStatement))
        let headers = (0..<count).map { String(cString: sqlite3_column_name(preparedStatement, Int32($0))) }
        let screen = terminalColumns()
        var rows: [[String]] = []
        while true {
            switch sqlite3_step(preparedStatement) {
            case SQLITE_ROW:
                rows.append((0..<count).map { clip(Self.value(preparedStatement, column: Int32($0)), width: screen) })
            case SQLITE_DONE:
                let widths = compactWidths(headers: headers, rows: rows, screen: screen)
                print(formatCompact((0..<count).map { clip(headers[$0], width: widths[$0]) }, widths: widths))
                print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
                for row in rows {
                    print(formatCompact((0..<count).map { clip(row[$0], width: widths[$0]) }, widths: widths))
                }
                print("\nTotal rows read: \(rows.count)")
                return
            default:
                throw sqliteError(Errors.Database.readingQuery(sql))
            }
        }
    }

    private func terminalColumns() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 1 {
            return Int(size.ws_col)
        }
        return 80
    }

    private func compactWidths(headers: [String], rows: [[String]], screen: Int) -> [Int] {
        let count = headers.count
        guard count > 0 else { return [] }
        let gaps = 2 * max(0, count - 1)
        let usable = max(count, screen - gaps)
        let share = usable / count
        var widths = Array(repeating: share, count: count)
        widths[count - 1] += usable - share * count
        let needed = (0..<count).map { index in
            max(headers[index].count, rows.map { $0[index].count }.max() ?? 0, 1)
        }
        guard needed.contains(where: { $0 > share }) else { return widths }
        var free = 0
        for index in 0..<count where needed[index] < widths[index] {
            free += widths[index] - needed[index]
            widths[index] = needed[index]
        }
        let hungry = (0..<count).filter { needed[$0] > widths[$0] }
        var remaining = free
        for index in hungry {
            let want = needed[index] - widths[index]
            let give = min(want, remaining)
            widths[index] += give
            remaining -= give
            if remaining == 0 { break }
        }
        return widths
    }

    private func formatCompact(_ cells: [String], widths: [Int]) -> String {
        cells.enumerated().map { index, cell in
            cell + String(repeating: " ", count: max(0, widths[index] - cell.count))
        }.joined(separator: "  ")
    }

    private func clip(_ text: String, width: Int) -> String {
        let clean = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        guard clean.count > width, width > 0 else { return clean }
        if width == 1 { return "…" }
        return String(clean.prefix(width - 1)) + "…"
    }

    private func forEachRow(
        _ sql: String,
        parameters: [SQLValue] = [],
        body: (OpaquePointer) -> Void
    ) throws {
        var preparedStatement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &preparedStatement, nil)
        defer {
            if let preparedStatement {
                sqlite3_finalize(preparedStatement)
            }
        }

        guard result == SQLITE_OK, let preparedStatement else {
            throw sqliteError(Errors.Database.preparingQuery(sql))
        }

        try bind(parameters, to: preparedStatement)
        while true {
            switch sqlite3_step(preparedStatement) {
            case SQLITE_ROW:
                body(preparedStatement)
            case SQLITE_DONE:
                return
            default:
                throw sqliteError(Errors.Database.readingQuery(sql))
            }
        }
    }

    func bind(_ parameters: [SQLValue], to statement: OpaquePointer) throws {
        guard Int(sqlite3_bind_parameter_count(statement)) == parameters.count else {
            throw InspectionError.sqlite(operation: Errors.Database.binding, message: Errors.Database.parameterCount)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case let .text(text):
                result = text.withCString { sqlite3_bind_text(statement, position, $0, -1, transient) }
            case let .integer(number):
                result = sqlite3_bind_int64(statement, position, number)
            case let .real(number):
                result = sqlite3_bind_double(statement, position, number)
            }
            guard result == SQLITE_OK else { throw sqliteError(Errors.Database.bindingValue) }
        }
    }

    private static func limitClause(_ limit: Int?) -> String {
        guard let limit, limit > 0 else { return "" }
        return " LIMIT \(limit)"
    }

    func structuredRows(_ sql: String, parameters: [SQLValue] = []) throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        try forEachRow(sql, parameters: parameters) { statement in
            rows.append(Self.structuredRow(statement))
        }
        return rows
    }

    static func structuredRow(_ statement: OpaquePointer) -> [String: Any] {
        var row: [String: Any] = [:]
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            switch sqlite3_column_type(statement, column) {
            case SQLITE_NULL:
                row[name] = NSNull()
            case SQLITE_INTEGER:
                row[name] = sqlite3_column_int64(statement, column)
            case SQLITE_FLOAT:
                let number = sqlite3_column_double(statement, column)
                row[name] = number.isFinite ? number as Any : ["type": "real", "value": String(number)]
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, column))
                let hex: String
                if let pointer = sqlite3_column_blob(statement, column), count > 0 {
                    hex = UnsafeRawBufferPointer(start: pointer, count: count).map { String(format: "%02X", $0) }.joined()
                } else { hex = "" }
                row[name] = ["type": "blob", "hex": hex]
            default:
                row[name] = Self.text(statement, column: column)
            }
        }
        return row
    }

    static func quotedIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else {
            return "NULL"
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    static func value(_ statement: OpaquePointer, column: Int32) -> String {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return "NULL"
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(statement, column))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
                return "BLOB (0 bytes): X''"
            }
            let bytes = UnsafeRawBufferPointer(start: pointer, count: count)
            let hex = bytes.map { String(format: "%02X", $0) }.joined()
            return "BLOB (\(count) bytes): X'\(hex)'"
        default:
            return text(statement, column: column)
        }
    }
}
