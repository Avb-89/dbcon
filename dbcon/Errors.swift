//
//  Errors.swift
//  dbcon
//
//  Created by SITIS on 11/13/26.
//

import Darwin
import Foundation
import SQLite3

enum Errors {
    static let writeReadOnly = "Read-only mode. Restart dbcon with -w to change data."
    static let saveReadOnly = "SAVE requires write mode. Restart dbcon with -w to make and save changes."
    static let cancelReadOnly = "Read-only mode: no changes were made. CANCEL is not needed."
    static let attachment = "This session works with one database. Exit and select another using dbcon -db <file> or --config <file>."
    static let transactionReadOnly = "Transaction and savepoint commands require write mode. Restart dbcon with -w."
    static let maintenanceShellOnly = "PRAGMA is available only as SQL in the dbcon shell, not through command-line flags."
    static let maintenanceReadOnly = "This PRAGMA is not allowed in read-only mode. Restart dbcon with -w to change settings or run other maintenance operations. Read-only inspection PRAGMAs remain available."
    static let deleteAlias = "The -d alias is not supported. Use --delete explicitly."

    enum CLI {
        static let invalidNames = "Table and column names must not be empty or contain null bytes."
        static let emptyNames = "Provide a name, not only a comma."
        static func duplicateNames(_ flag: String) -> String { "Duplicate names in \(flag)." }
        static func wildcardNames(_ flag: String) -> String { "Use '*' alone in \(flag), without other names." }
        static func unknownArgument(_ flag: String) -> String { flag == "-d" ? Errors.deleteAlias : "Unknown argument: \(flag). Use --help for usage." }
        static func startupOption(_ flag: String) -> String { "\(flag) is a startup option. Exit the shell and pass it when launching dbcon." }
        static func duplicateOption(_ flag: String) -> String { "Duplicate option: \(flag)." }
        static func sqlListRequired(_ flag: String) -> String { "\(flag) requires a nonempty SQL expression list." }
        static func textRequired(_ flag: String) -> String { "\(flag) requires nonempty text." }
        static func valueRequired(_ flag: String) -> String { "\(flag) requires a nonempty value." }
        static func pathRequired(_ flag: String) -> String { "\(flag) requires a nonempty file path." }
        static func columnsRequired(_ flag: String) -> String { "\(flag) requires column names, or '*'." }
        static func tablesRequired(_ flag: String) -> String { "\(flag) requires at least one table name or '*'." }
        static let timeoutRequired = "--timeout requires a whole number of at least 1000."
        static let limitRequired = "-n requires a whole number of at least 1."
        static let accessConflict = "Choose either -r or -w, not both."
        static let tableConflict = "Choose either --tables, --table or -t, not more than one."
        static let structureConflict = "--columns lists structure. Use --column or -c to select fields for a read or search."
        static let columnsNeedTable = "--column and -c require -t <table> or --table <name>."
        static let nonEmptyNeedsCount = "--non-empty and -p require --count."
        static let countNeedsTable = "--count requires -t <table> or --table <name>."
        static let sortNeedsRead = "--order-by and --sort require a read or search."
        static let countConflict = "--count cannot be combined with reading, structure, -f, or -n."
        static let countColumns = "Column selection with --count requires -p or --search."
        static let writeConflict = "Choose only one of --insert, --update, or --delete."
        static let writeTable = "Writing requires exactly one literal table with --table or -t."
        static let insertValues = "--insert requires --values."
        static let updateSet = "--update requires --set."
        static let writeOption = "Unsupported option for this write action. Use --help."
        static let writeArguments = "--values requires --insert; --set requires --update."
        static let searchModesNeedSearch = "-i, -e, --eq, and --equal require -s or --search."
        static let helpAlone = "Use --help alone."
        static let manualAlone = "Use --man [en|ru] alone."
        static let configAlone = "Use --set-config alone."
        static let mcpOptions = "--mcp accepts only --db, --config, --timeout, and exactly one of -r or -w."
        static let mcpModeRequired = "MCP requires an explicit access mode. Use --mcp -r for reading or --mcp -w for reading and writing."
        static let searchReadConflict = "Choose either --search or --read, not both."
        static let searchNeedsTable = "--search requires -t <table> or --table <name>."
        static let caseModesNeedSearch = "-i and -e require -s or --search."
        static let structureNeedsTable = "--columns requires -t <table> or --table <name>."
        static let readTableNames = "To read data, provide table names after --tables or use -t."
        static let readNeedsTable = "Reading requires -t <table> or --table <name>."
        static let filterAction = "--where requires a read, search, count, update, or delete; --order-by/--sort require reading or searching."
        static let compactNeedsRead = "-f requires a read or search."
        static let limitNeedsRead = "-n requires a read or search."
        static func clusterValue(_ letter: Character, in value: String) -> String { "Cannot combine -\(letter) in \(value). Flags with values must stand alone." }
        static let clusterHelp = "Cannot combine -h with other flags."
        static func clusterGroups(_ value: String) -> String { "Cannot combine flags from different groups: \(value)." }
    }

    enum Search {
        static let arrayPath = "Array selectors support one [*], followed by .name or [nonnegative index] steps. Filter element types explicitly when technical blocks must be excluded."
        static let episode = "window_rows > 1 requires group_by and order_by. max_gap_seconds also requires a numeric time_column with time_unit seconds or milliseconds."
        static let alternatives = "required_groups entries contain nonempty alternatives separated by '|'. At most 32 conditions and 32 alternatives per group are allowed."
        static let cli = "Advanced search requires one literal table, --key and explicit -c fields. Use --find for ranked search or --context with --anchor for context; do not mix write/count/structure flags."
        static let optionValue = "Missing, duplicate, out-of-range, or unsupported search option. See --man."
        static let fields = "Use distinct existing fields or supported JSON text selectors. '*' is not allowed; [*] is limited to selected text fields."
        static let keys = "key_columns must be existing literal columns forming a unique, non-NULL key across the table."
        static let terms = "Provide at least one search, required_groups or phrases condition; at most 32 conditions. Normalized terms must not be empty."
        static let order = "sort: fields requires order_by. Include a meaningful chronological field when requesting recent records."
        static let timestamp = "time_column requires time_unit (seconds, milliseconds, or iso8601); time_zone must be a valid time zone identifier."
        static let invalidTime = "Invalid timestamp for the declared time_unit; ISO-8601 text must include a time zone."
        static let anchor = "anchor_where must identify exactly one row within where; no context was returned."
        static let relation = "Related context requires source_field and related_field together; use the related table's own key_columns and order_by."
        static let scalar = "Keys, relation values, and time fields must be scalar text or finite numbers; NULL relation values cannot select context."
        static let budget = "max_bytes is too small for the response metadata or the next result. Increase max_bytes or request fewer/smaller fields."
    }

    enum Query {
        static func unknownField(_ field: String) -> String { "Unknown column or JSON field: \(field)." }
        static func invalidJSONPath(_ field: String) -> String { "Invalid JSON path in \(field)." }
        static let columnsRequired = "Provide column names or '*' alone."
        static let emptySearchField = "Search field must not be empty."
        static let emptySortField = "--order-by contains an empty field."
        static let sortFieldRequired = "--order-by requires a field."
        static func invalidSortField(_ text: String) -> String { "Invalid sort field: \(text)." }
        static let unexpectedFilterText = "Unexpected text in --where."
        static let missingParenthesis = "--where is missing a closing parenthesis."
        static let fieldRequired = "--where requires a field."
        static let nullRequired = "--where requires NULL after IS."
        static let operatorRequired = "--where requires an operator."
        static let valueRequired = "--where requires a value."
        static func numberOutOfRange(_ text: String) -> String { "Invalid or out-of-range number in --where: \(text). Quote text values." }
        static let keywordValue = "Use IS NULL / IS NOT NULL for nulls; quote keyword text values in --where."
        static let valueAfterOperator = "--where requires a value after the operator."
        static let unclosedQuote = "Unclosed quote in --where."
        static let invalidSyntax = "Invalid --where syntax."
        static func invalidNumber(_ word: String) -> String { "Invalid number in --where: \(word). Quote text values." }
    }

    enum Configuration {
        static let connectionHint = "Add --db /path/base.db, select a configuration with --config <path>, or save a default with --set-config."
        static let noExecutable = "Could not determine the executable location."
        static func loadFailed(_ path: String, detail: String) -> String { "Cannot load configuration '\(path)': \(detail)" }
        static func databasePathRequired(_ path: String) -> String { "Set a valid databasePath in '\(path)'." }
        static func timeoutRequired(_ path: String) -> String { "busyTimeoutMilliseconds must be at least 1000 in '\(path)'." }
        static func settingsFormat(_ path: String) -> String { "Invalid settings file: \(path). Expected configPath=<path>." }
        static func settingsPath(_ path: String) -> String { "Invalid configPath in '\(path)'." }
        static let interactiveRequired = "dbcon --set-config requires an interactive terminal."
        static let nothingCreated = "Nothing was created."
        static let invalidPath = "Invalid configuration path.\n\(nothingCreated)"
        static func notAFile(_ path: String) -> String { "Not a configuration file: \(path)\n\(nothingCreated)" }
        static func notFound(_ path: String) -> String { "Configuration file was not found: \(path)" }
        static func cannotLoad(_ path: String) -> String { "Cannot load configuration: \(path)" }
        static let booleanRequired = "Enter true or false."
        static let timeoutInput = "Enter at least 1000."
        static let confirmationRequired = "Enter y or n."
        static let lineBreaks = "Configuration paths must not contain line breaks."
        static let databasePathHelp = """
        Invalid database path.
        The path must name an existing SQLite file.
        Examples:
          ~/data/work.db
          /absolute/path/work.db
          ./work.db
        A relative path is resolved from the directory that contains the JSON file, not from the current directory.
        Start the wizard again with:
          dbcon --set-config
        \(nothingCreated)
        """
    }

    enum Shell {
        static let tablesAlone = "Use TABLES alone to list tables."
        static let unknownCommand = "Unknown command. Use SELECT, TABLES, COLUMNS, COUNT, or -s."
        static let actionRequired = "Specify a table and an action inside the shell."
        static let unclosedQuote = "Unclosed quote or trailing escape."
        static let unfinishedCommand = "Discarding unfinished command (no GO)."
        static let rollbackOnExit = "Closing shell: rolling back unsaved changes."
    }

    enum Writing {
        static let transactionMode = "Unknown transaction mode."
        static let nullSQL = "SQL must not contain null bytes."
        static let singleStatement = "Write flags accept one statement. Use direct SQL in the shell for a batch."
        static func unknownColumn(_ column: String) -> String { "Unknown insert column: \(column)." }
        static let actionRequired = "Expected --insert, --update, or --delete."
        static let transactionRolledBack = "The transaction was rolled back."
        static let sqliteRolledBack = "SQLite rolled back the transaction; earlier unsaved changes were also cancelled."
    }

    enum Database {
        static let noConnection = "SQLite did not create a connection."
        static let timeoutMinimum = "busyTimeoutMilliseconds must be at least 1000."
        static let tablesRequired = "Provide at least one table name."
        static func missingTable(_ table: String) -> String { "Table '\(table)' does not exist." }
        static let parameterCount = "Parameter count does not match the query."
        static let opening = "Opening database"
        static let timeout = "Setting busy timeout"
        static let selectingTables = "Selecting tables"
        static let binding = "Binding query"
        static let bindingValue = "Binding query value"
        static let preparingSearch = "Preparing search"
        static let writing = "Writing"
        static let saving = "SAVE"
        static let maintenance = "Maintenance"
        static let protectingSQL = "Protecting SQL execution"
        static let preparingSQL = "Preparing SQL"
        static let preparingBatch = "Preparing SQL batch"
        static let executingSQL = "Executing SQL"
        static func executing(_ sql: String) -> String { "Executing \(sql)" }
        static func preparingQuery(_ sql: String) -> String { "Preparing query \(sql)" }
        static func readingQuery(_ sql: String) -> String { "Reading query result \(sql)" }
    }

    enum RPC {
        static let singleWriteStatement = "Each MCP write operation accepts one statement. Use write_batch for multiple operations."
        static let writeShape = "Invalid write arguments. Use the tool schema; insert requires values, update requires set, and update/delete require nonempty where or all_rows: true, not both."
        static let writeColumns = "Use existing literal column names without duplicates; '*' is not a write or returning column."
        static let writeBatch = "operations must be a nonempty array of insert/update/delete objects."
        static let pendingTransaction = "An unexpected transaction is active; no new MCP write was started."
        static func batchFailure(_ operation: Int, detail: String, rollback: String) -> String {
            "Operation \(operation) failed: \(detail)\n\(rollback)"
        }
        static let batchRolledBack = "The entire call was rolled back; no changes from this call were saved."
        static func rollbackFailed(_ detail: String) -> String { "Rollback failed: \(detail). The MCP connection will close; do not retry blindly." }
        static let parse = "Parse error: expected one JSON message per line."
        static let invalidRequest = "Invalid JSON-RPC request."
        static let invalidMethodID = "Invalid method or request ID."
        static let paramsObject = "params must be an object."
        static let alreadyInitialized = "This connection is already initialized."
        static let initializeArguments = "initialize requires protocolVersion, capabilities, and clientInfo."
        static let initializeFirst = "Send initialize and notifications/initialized before using tools."
        static let listArguments = "tools/list accepts only optional _meta; all tools fit on one page."
        static let unknownTool = "Unknown or missing tool name."
        static let argumentsObject = "arguments must be an object."
        static func unknownMethod(_ method: String) -> String { "Method not found: \(method)." }
        static func missingTable(_ table: String) -> String { "Table '\(table)' does not exist. Use list_tables first." }
        static let searchRequired = "ignore_case and exact require a nonempty search array."
        static let countColumns = "columns with count_rows requires non_empty or search."
        static func unknownArguments(allowed: [String], required: [String]) -> String {
            "Unknown or missing arguments. Allowed: \(allowed.joined(separator: ", ")); required: \(required.joined(separator: ", "))."
        }
        static func invalidArgument(_ key: String, expected: String?) -> String {
            "Invalid argument '\(key)'. Expected \(expected ?? "a valid value")."
        }
    }

    static func format(_ message: String) -> String {
        "Error: \(message)"
    }

    static func sqliteFailure(operation: String, path: String, database: OpaquePointer?, result: Int32? = nil) -> DatabaseInspector.InspectionError {
        let extended = database.map { sqlite3_extended_errcode($0) } ?? result ?? SQLITE_ERROR
        let primary = extended & 0xff
        var message = database.map { String(cString: sqlite3_errmsg($0)) } ?? Database.noConnection
        let accessCodes: Set<Int32> = [SQLITE_CANTOPEN, SQLITE_IOERR, SQLITE_READONLY, SQLITE_PERM, SQLITE_NOTADB, SQLITE_CORRUPT]
        if operation == Database.opening || accessCodes.contains(primary) {
            message += "\nDatabase: \(path)\nSQLite code: \(primary); extended code: \(extended)."
            if let database, (primary == SQLITE_CANTOPEN || primary == SQLITE_IOERR) {
                let systemCode = sqlite3_system_errno(database)
                if systemCode != 0, let detail = strerror(systemCode) {
                    message += "\nSystem error: \(systemCode) (\(String(cString: detail)))."
                }
            }
        }
        return .sqlite(operation: operation, message: message)
    }
}

extension DatabaseInspector {
    enum InspectionError: LocalizedError {
        case sqlite(operation: String, message: String)

        var errorDescription: String? {
            switch self {
            case let .sqlite(operation, message): return "\(operation): \(message)"
            }
        }
    }

    func denySQL(_ message: String) -> Int32 {
        sqlDenial = message
        return SQLITE_DENY
    }

    func sqliteError(_ operation: String) -> InspectionError {
        if (sqlite3_errcode(database) & 0xff) == SQLITE_AUTH, let sqlDenial {
            return .sqlite(operation: operation, message: sqlDenial)
        }
        return Errors.sqliteFailure(operation: operation, path: databasePath, database: database)
    }
}

extension Arguments {
    enum ArgumentError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case let .invalid(message): return message
            }
        }
    }
}

extension Connector {
    enum StartupError: LocalizedError {
        case invalidConfiguration(String)
        var errorDescription: String? {
            switch self {
            case let .invalidConfiguration(message): return message
            }
        }
    }
}

extension Shell {
    enum ShellError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case let .invalid(message): return message
            }
        }
    }
}

extension MCP {
    struct RPCError: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }
}

extension Man {
    enum ManualError: LocalizedError {
        case missing
        case missingSection(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "Manual file Man.txt was not found."
            case let .missingSection(language): return "Manual file Man.txt has no \(language) section."
            }
        }
    }
}
