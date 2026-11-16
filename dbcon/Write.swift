//
//  Write.swift
//  dbcon
//
//  Created by SITIS on 11/13/26.
//

import Foundation
import SQLite3

extension DatabaseInspector {
    var hasTransaction: Bool { sqlite3_get_autocommit(database) == 0 }

    func beginChanges(mode: String = "DEFERRED") throws {
        try requireWriteAccess()
        guard ["DEFERRED", "IMMEDIATE", "EXCLUSIVE"].contains(mode) else {
            throw Arguments.ArgumentError.invalid(Errors.Writing.transactionMode)
        }
        if !hasTransaction { try control("BEGIN \(mode)") }
    }

    func saveChanges() throws {
        guard !readOnly else { throw InspectionError.sqlite(operation: Errors.Database.saving, message: Errors.saveReadOnly) }
        if hasTransaction { try control("COMMIT") }
        print("Changes saved.")
    }

    func cancelChanges() throws {
        if readOnly {
            print(Errors.cancelReadOnly)
            return
        }
        if hasTransaction { try control("ROLLBACK") }
        print("Changes cancelled.")
    }

    func requireWriteAccess() throws {
        guard !readOnly else {
            throw InspectionError.sqlite(operation: Errors.Database.writing, message: Errors.writeReadOnly)
        }
    }

    private func control(_ sql: String) throws {
        let previous = checkingUserSQL
        checkingUserSQL = false
        defer { checkingUserSQL = previous }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(Errors.Database.executing(sql))
        }
    }

    private func installSQLPolicy() throws {
        let result = sqlite3_set_authorizer(database, { context, action, first, argument, _, _ in
            guard let context else { return SQLITE_DENY }
            let inspector = Unmanaged<DatabaseInspector>.fromOpaque(context).takeUnretainedValue()
            guard inspector.checkingUserSQL else { return SQLITE_OK }
            switch action {
            case SQLITE_ATTACH, SQLITE_DETACH:
                return inspector.denySQL(Errors.attachment)
            case SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
                inspector.sqlTransaction = true
                return inspector.readOnly ? inspector.denySQL(Errors.transactionReadOnly) : SQLITE_OK
            case SQLITE_PRAGMA:
                return inspector.authorizeMaintenance(name: first, argument: argument)
            default:
                return SQLITE_OK
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard result == SQLITE_OK else { throw sqliteError(Errors.Database.protectingSQL) }
    }

    private func prepareSingleSQL(_ sql: String, multipleStatementMessage: String = Errors.Writing.singleStatement) throws -> OpaquePointer {
        guard !sql.contains("\0") else {
            throw InspectionError.sqlite(operation: Errors.Database.preparingSQL, message: Errors.Writing.nullSQL)
        }
        return try sql.withCString { start in
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let result = sqlite3_prepare_v2(database, start, -1, &statement, &tail)
            guard result == SQLITE_OK, let prepared = statement else {
                if let statement { sqlite3_finalize(statement) }
                throw sqliteError(Errors.Database.preparingSQL)
            }
            do {
                while let rest = tail, rest.pointee != 0 {
                    var extra: OpaquePointer?
                    var next: UnsafePointer<CChar>?
                    let status = sqlite3_prepare_v2(database, rest, -1, &extra, &next)
                    let hasExtra = extra != nil
                    if let extra { sqlite3_finalize(extra) }
                    guard status == SQLITE_OK, !hasExtra else {
                        throw InspectionError.sqlite(operation: Errors.Database.preparingSQL, message: multipleStatementMessage)
                    }
                    if next == rest { break }
                    tail = next
                }
                return prepared
            } catch {
                sqlite3_finalize(prepared)
                throw error
            }
        }
    }

    func executeSQL(_ sql: String, parameters: [SQLValue] = [], inShell: Bool) throws {
        try installSQLPolicy()
        checkingUserSQL = true
        allowsMaintenance = false
        sqlTransaction = false
        sqlDenial = nil
        defer {
            checkingUserSQL = false
            allowsMaintenance = false
            sqlite3_set_authorizer(database, nil, nil)
        }
        let statement = try prepareSingleSQL(sql)
        defer { sqlite3_finalize(statement) }
        try executePreparedSQL(statement, parameters: parameters, inShell: inShell)
    }

    func executeSQLBatch(_ sql: String) throws {
        guard !sql.contains("\0") else {
            throw InspectionError.sqlite(operation: Errors.Database.preparingSQL, message: Errors.Writing.nullSQL)
        }
        try installSQLPolicy()
        checkingUserSQL = true
        allowsMaintenance = true
        defer {
            checkingUserSQL = false
            allowsMaintenance = false
            sqlite3_set_authorizer(database, nil, nil)
        }
        try sql.withCString { start in
            var cursor = start
            while cursor.pointee != 0 {
                sqlTransaction = false
                sqlDenial = nil
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let result = sqlite3_prepare_v2(database, cursor, -1, &statement, &tail)
                do {
                    guard result == SQLITE_OK else { throw sqliteError(Errors.Database.preparingBatch) }
                    if let statement {
                        if Self.isMaintenanceStatement(statement) {
                            try bind([], to: statement)
                            try executeMaintenance(statement)
                        } else {
                            try executePreparedSQL(statement, parameters: [], inShell: true, transaction: sqlTransaction)
                        }
                    }
                } catch {
                    if let statement { sqlite3_finalize(statement) }
                    throw error
                }
                if let statement { sqlite3_finalize(statement) }
                guard let tail, tail != cursor else { break }
                cursor = tail
            }
        }
    }

    func consumeSQLResult(_ statement: OpaquePointer) throws {
        var rows = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw sqliteError(Errors.Database.executingSQL) }
            rows += 1
            print("\n--- Row \(rows) ---")
            for column in 0..<sqlite3_column_count(statement) {
                print("\(String(cString: sqlite3_column_name(statement, column))):")
                print(Self.value(statement, column: column))
            }
        }
        if sqlite3_column_count(statement) > 0 { print("\nTotal rows read: \(rows)") }
    }

    private func executePreparedSQL(_ statement: OpaquePointer, parameters: [SQLValue], inShell: Bool, transaction: Bool = false) throws {
        try bind(parameters, to: statement)
        if transaction {
            try requireWriteAccess()
            try consumeSQLResult(statement)
            print(hasTransaction ? "Transaction active." : "Transaction closed.")
            return
        }
        let writes = sqlite3_stmt_readonly(statement) == 0
        let savepoint = "dbcon_command_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if writes {
            try requireWriteAccess()
            try beginChanges()
            try control("SAVEPOINT \(savepoint)")
        }
        let before = sqlite3_total_changes64(database)
        do {
            try consumeSQLResult(statement)
            if writes {
                try control("RELEASE \(savepoint)")
                if !inShell { try control("COMMIT") }
                print("Rows changed (including triggers): \(sqlite3_total_changes64(database) - before)")
                print(inShell ? "Not saved. Use SAVE or CANCEL." : "Changes saved.")
            }
        } catch {
            sqlite3_reset(statement)
            if writes, hasTransaction {
                if inShell {
                    do {
                        try control("ROLLBACK TO \(savepoint)")
                        try control("RELEASE \(savepoint)")
                    } catch {
                        try? control("ROLLBACK")
                        print(Errors.Writing.transactionRolledBack)
                    }
                } else {
                    try? control("ROLLBACK")
                }
            } else if writes {
                print(Errors.Writing.sqliteRolledBack)
            }
            throw error
        }
    }

    func write(_ arguments: Arguments, inShell: Bool = false) throws {
        try requireWriteAccess()
        let table = try selectedTables(arguments.tableNames)[0]
        let available = try columnNames(table)
        let target = Self.quotedIdentifier(table)
        switch arguments.action {
        case .insert:
            let fields: String
            if arguments.columnNames == ["*"] {
                fields = ""
            } else {
                for column in arguments.columnNames where !available.contains(column) {
                    throw Arguments.ArgumentError.invalid(Errors.Writing.unknownColumn(column))
                }
                fields = " (" + arguments.columnNames.map(Self.quotedIdentifier).joined(separator: ", ") + ")"
            }
            guard let values = arguments.valueExpressions else { throw Arguments.ArgumentError.invalid(Errors.CLI.insertValues) }
            try executeSQL("INSERT INTO \(target)\(fields) VALUES (\(values))", inShell: inShell)
        case .update, .delete:
            let query = try QuerySQL(columns: ["*"], available: available, terms: [], conditions: arguments.whereTexts, orderFields: [], ignoreCase: false, exact: false)
            let sql: String
            if arguments.action == .update {
                guard let assignments = arguments.assignments else { throw Arguments.ArgumentError.invalid(Errors.CLI.updateSet) }
                sql = "UPDATE \(target) SET \(assignments) WHERE \(query.filter)"
            } else {
                sql = "DELETE FROM \(target) WHERE \(query.filter)"
            }
            try executeSQL(sql, parameters: query.parameters, inShell: inShell)
        default:
            throw Arguments.ArgumentError.invalid(Errors.Writing.actionRequired)
        }
    }

    func commitMCPChanges() throws { try control("COMMIT") }

    func rollbackMCPChanges() throws {
        if hasTransaction { try control("ROLLBACK") }
    }

    func executeMCPStatement(_ sql: String, parameters: [SQLValue]) throws -> [String: Any] {
        try requireWriteAccess()
        try installSQLPolicy()
        checkingUserSQL = true
        allowsMaintenance = false
        sqlDenial = nil
        defer {
            checkingUserSQL = false
            sqlite3_set_authorizer(database, nil, nil)
        }
        let statement = try prepareSingleSQL(sql, multipleStatementMessage: Errors.RPC.singleWriteStatement)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        let before = sqlite3_total_changes64(database)
        var rows: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw sqliteError(Errors.Database.executingSQL) }
            rows.append(Self.structuredRow(statement))
        }
        var result: [String: Any] = ["rows_changed": sqlite3_changes64(database), "rows_changed_including_triggers": sqlite3_total_changes64(database) - before]
        if sqlite3_column_count(statement) > 0 { result["returned_rows"] = rows }
        return result
    }
}
