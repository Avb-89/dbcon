//
//  Maintenance.swift
//  dbcon
//
//  Created by SITIS on 11/13/26.
//

import Foundation
import SQLite3

extension DatabaseInspector {
    func authorizeMaintenance(name: UnsafePointer<CChar>?, argument: UnsafePointer<CChar>?) -> Int32 {
        guard allowsMaintenance else { return denySQL(Errors.maintenanceShellOnly) }
        guard readOnly else { return SQLITE_OK }
        let pragma = name.map { String(cString: $0).lowercased() } ?? ""
        let inspection: Set<String> = [
            "table_info", "table_xinfo", "table_list", "index_info", "index_xinfo",
            "index_list", "foreign_key_list", "foreign_key_check", "integrity_check",
            "quick_check", "database_list", "compile_options"
        ]
        if inspection.contains(pragma) { return SQLITE_OK }
        let getters: Set<String> = [
            "application_id", "auto_vacuum", "automatic_index", "busy_timeout",
            "cache_size", "cache_spill", "cell_size_check", "checkpoint_fullfsync",
            "collation_list", "data_version", "defer_foreign_keys", "encoding",
            "foreign_keys", "freelist_count", "fullfsync", "function_list",
            "hard_heap_limit", "ignore_check_constraints", "journal_mode",
            "journal_size_limit", "legacy_alter_table", "locking_mode",
            "max_page_count", "mmap_size", "module_list", "page_count", "page_size",
            "pragma_list", "query_only", "read_uncommitted", "recursive_triggers",
            "reverse_unordered_selects", "schema_version", "secure_delete",
            "soft_heap_limit", "synchronous", "temp_store", "threads",
            "trusted_schema", "user_version", "wal_autocheckpoint", "writable_schema"
        ]
        return argument == nil && getters.contains(pragma) ? SQLITE_OK : denySQL(Errors.maintenanceReadOnly)
    }

    static func isMaintenanceStatement(_ statement: OpaquePointer) -> Bool {
        guard let raw = sqlite3_sql(statement) else { return false }
        var text = String(cString: raw)[...]
        while true {
            text = text.drop(while: { $0.isWhitespace || $0 == ";" })
            if text.hasPrefix("--") {
                guard let end = text.firstIndex(of: "\n") else { return false }
                text = text[text.index(after: end)...]
            } else if text.hasPrefix("/*") {
                guard let end = text.range(of: "*/") else { return false }
                text = text[end.upperBound...]
            } else {
                return text.prefix(while: { $0.isLetter }).uppercased() == "PRAGMA"
            }
        }
    }

    func executeMaintenance(_ statement: OpaquePointer) throws {
        guard allowsMaintenance else {
            throw InspectionError.sqlite(operation: Errors.Database.maintenance, message: Errors.maintenanceShellOnly)
        }
        try consumeSQLResult(statement)
        print("PRAGMA completed.")
    }
}
