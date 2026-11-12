//
//  Arguments.swift
//  dbcon
//
//  Created by SITIS on 11/11/26.
//

import Foundation

struct Arguments {
    enum Action {
        case help
        case tables
        case columns
        case count
        case read
        case search
        case shell
        case setConfiguration
        case manual
        case mcp
    }

    enum ArgumentError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(message):
                return message
            }
        }
    }

    let action: Action
    let configurationPath: String?
    let databasePath: String?
    let permanentConfigurationPath: String?
    let readOnly: Bool?
    let manualLanguage: String?
    let tableNames: [String]
    let columnNames: [String]
    let searchTexts: [String]
    let whereTexts: [String]
    let orderFields: [String]
    let ignoreCase: Bool
    let exact: Bool
    let compact: Bool
    let rowLimit: Int?
    let busyTimeout: Int32?
    var nonEmpty = false

    init(_ values: [String], inShell: Bool = false) throws {
        let values = try Self.expandClusters(values)
        if values.isEmpty {
            self = .shellDefaults
            return
        }
        if values == ["--help"] || values == ["-h"] {
            self = .helpDefaults
            return
        }

        var index = 0
        var seen = Set<String>()
        var config: String?
        var database: String?
        var tables: [String] = []
        var columns: [String] = []
        var manual: String?
        var search: [String] = []
        var filters: [String] = []
        var order: [String] = []
        var limit: Int?
        var timeout: Int32?

        func takeNames(_ flag: String) throws -> [String] {
            var names: [String] = []
            while index < values.count, !values[index].hasPrefix("-") {
                let name = values[index]
                guard !name.isEmpty, !name.contains("\0") else {
                    throw ArgumentError.invalid("Table and column names must not be empty or contain null bytes.")
                }
                let parts = name.split(separator: ",", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !parts.isEmpty else {
                    throw ArgumentError.invalid("Provide a name, not only a comma.")
                }
                names.append(contentsOf: parts)
                index += 1
            }
            guard Set(names).count == names.count else {
                throw ArgumentError.invalid("Duplicate names in \(flag).")
            }
            guard !names.contains("*") || names.count == 1 else {
                throw ArgumentError.invalid("Use '*' alone in \(flag), without other names.")
            }
            return names
        }

        while index < values.count {
            let flag = values[index]
            let supported = [
                "--config", "--set-config", "--mcp", "--db", "--tables", "--table", "--column", "--columns", "--read",
                "--search", "--where", "--order-by", "--man", "--help", "--timeout", "-r", "-w", "-i", "-e", "-f", "-h",
                "-t", "-c", "-n", "-s", "--count", "--non-empty", "-p"
            ]
            let option = ["-db": "--db", "--eq": "-e", "--equal": "-e", "--sort": "--order-by"][flag] ?? flag
            guard supported.contains(option) else {
                throw ArgumentError.invalid("Unknown argument: \(flag). Use --help for usage.")
            }
            if inShell, ["--db", "--config", "--set-config", "--mcp", "--timeout", "-r", "-w"].contains(option) {
                throw ArgumentError.invalid("\(flag) is a startup option. Exit the shell and pass it when launching dbcon.")
            }
            let seenKey = ["-t": "--table", "-c": "--column", "-s": "--search", "-p": "--non-empty"][option] ?? option
            let repeatable = ["--search", "--where", "--order-by"]
            guard seen.insert(seenKey).inserted || repeatable.contains(seenKey) else {
                throw ArgumentError.invalid("Duplicate option: \(flag).")
            }
            index += 1

            switch option {
            case "--man":
                if index < values.count, ["en", "ru"].contains(values[index]) {
                    manual = values[index]
                    index += 1
                } else {
                    manual = "en"
                }
            case "--set-config", "--mcp", "--read", "--columns", "--count", "--non-empty", "-p", "-i", "-e", "-f", "-h", "--help":
                break
            case "--search", "-s":
                guard index < values.count, !values[index].hasPrefix("-"),
                      !values[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !values[index].contains("\0") else {
                    throw ArgumentError.invalid("\(flag) requires nonempty text.")
                }
                search.append(values[index])
                index += 1
            case "--where", "--order-by":
                guard index < values.count, !values[index].hasPrefix("-"),
                      !values[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !values[index].contains("\0") else {
                    throw ArgumentError.invalid("\(flag) requires a nonempty value.")
                }
                if option == "--where" {
                    filters.append(values[index])
                } else {
                    order.append(values[index])
                }
                index += 1
            case "--config", "--db":
                guard index < values.count, !values[index].hasPrefix("-"),
                      !values[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !values[index].contains("\0") else {
                    throw ArgumentError.invalid("\(flag) requires a nonempty file path.")
                }
                if option == "--config" {
                    config = values[index]
                } else {
                    database = values[index]
                }
                index += 1
            case "--timeout":
                guard index < values.count, let value = Int32(values[index]), value >= 1000 else {
                    throw ArgumentError.invalid("--timeout requires a whole number of at least 1000.")
                }
                timeout = value
                index += 1
            case "-n":
                guard index < values.count, let value = Int(values[index]), value >= 1 else {
                    throw ArgumentError.invalid("-n requires a whole number of at least 1.")
                }
                limit = value
                index += 1
            case "--tables", "--table", "-t", "--column", "-c":
                let names = try takeNames(flag)
                if option == "--column" || option == "-c" {
                    guard !names.isEmpty else {
                        throw ArgumentError.invalid("\(flag) requires column names, or '*'.")
                    }
                    columns = names
                } else {
                    guard option == "--tables" || !names.isEmpty else {
                        throw ArgumentError.invalid("\(flag) requires at least one table name or '*'.")
                    }
                    tables = names
                }
            default:
                break
            }
        }

        guard !(seen.contains("-r") && seen.contains("-w")) else {
            throw ArgumentError.invalid("Choose either -r or -w, not both.")
        }
        guard !(seen.contains("--tables") && seen.contains("--table")) else {
            throw ArgumentError.invalid("Choose either --tables, --table or -t, not more than one.")
        }
        if seen.contains("--columns") {
            guard !seen.contains("--column"), !seen.contains("--read"), !seen.contains("--where"), !seen.contains("--order-by"), search.isEmpty else {
                throw ArgumentError.invalid("--columns lists structure. Use --column or -c to select fields for a read or search.")
            }
        }
        if seen.contains("--column"), tables.isEmpty {
            throw ArgumentError.invalid("--column and -c require -t <table> or --table <name>.")
        }
        if seen.contains("--non-empty"), !seen.contains("--count") {
            throw ArgumentError.invalid("--non-empty and -p require --count.")
        }
        if seen.contains("--count") {
            guard !tables.isEmpty else {
                throw ArgumentError.invalid("--count requires -t <table> or --table <name>.")
            }
            guard !seen.contains("--order-by") else {
                throw ArgumentError.invalid("--order-by and --sort require a read or search.")
            }
            guard seen.isDisjoint(with: ["--read", "--columns", "-f", "-n"]) else {
                throw ArgumentError.invalid("--count cannot be combined with reading, structure, -f, or -n.")
            }
            guard !seen.contains("--column") || seen.contains("--non-empty") || !search.isEmpty else {
                throw ArgumentError.invalid("Column selection with --count requires -p or --search.")
            }
        }

        if search.isEmpty, seen.contains("-i") || seen.contains("-e") {
            throw ArgumentError.invalid("-i, -e, --eq, and --equal require -s or --search.")
        }
        let selected: Action
        if seen.contains("--help") || seen.contains("-h") {
            guard seen.subtracting(["--help", "-h"]).isEmpty else {
                throw ArgumentError.invalid("Use --help alone.")
            }
            selected = .help
        } else if manual != nil {
            guard seen == Set(["--man"]) else {
                throw ArgumentError.invalid("Use --man [en|ru] alone.")
            }
            selected = .manual
        } else if seen.contains("--set-config") {
            guard seen == Set(["--set-config"]) else {
                throw ArgumentError.invalid("Use --set-config alone.")
            }
            selected = .setConfiguration
        } else if seen.contains("--mcp") {
            guard seen.isSubset(of: ["--mcp", "--db", "--config", "--timeout", "-r"]) else {
                throw ArgumentError.invalid("--mcp accepts only --db, --config, --timeout, and -r. MCP is read-only.")
            }
            selected = .mcp
        } else if seen.contains("--count") {
            selected = .count
        } else if !search.isEmpty {
            guard !seen.contains("--read") else {
                throw ArgumentError.invalid("Choose either --search or --read, not both.")
            }
            guard !tables.isEmpty else {
                throw ArgumentError.invalid("--search requires -t <table> or --table <name>.")
            }
            selected = .search
        } else if seen.contains("-i") || seen.contains("-e") {
            throw ArgumentError.invalid("-i and -e require -s or --search.")
        } else if seen.contains("--columns") {
            guard !tables.isEmpty else {
                throw ArgumentError.invalid("--columns requires -t <table> or --table <name>.")
            }
            selected = .columns
        } else if seen.contains("--tables"), tables.isEmpty {
            guard !seen.contains("--read"), !seen.contains("-f"), limit == nil else {
                throw ArgumentError.invalid("To read data, provide table names after --tables or use -t.")
            }
            selected = .tables
        } else if seen.contains("--read") || !tables.isEmpty || seen.contains("-f") || limit != nil || seen.contains("--where") || seen.contains("--order-by") {
            guard !tables.isEmpty else {
                throw ArgumentError.invalid("Reading requires -t <table> or --table <name>.")
            }
            selected = .read
        } else {
            selected = .shell
        }

        if seen.contains("--where") || seen.contains("--order-by"), selected != .read, selected != .search, selected != .count {
            throw ArgumentError.invalid("--where, --order-by, and --sort require a read, search, or count.")
        }
        if seen.contains("--order-by"), selected == .count {
            throw ArgumentError.invalid("--order-by and --sort require a read or search.")
        }
        if seen.contains("-f"), selected != .read, selected != .search {
            throw ArgumentError.invalid("-f requires a read or search.")
        }
        if limit != nil, selected != .read, selected != .search {
            throw ArgumentError.invalid("-n requires a read or search.")
        }

        action = selected
        configurationPath = config
        databasePath = database
        permanentConfigurationPath = nil
        readOnly = seen.contains("-r") ? true : (seen.contains("-w") ? false : nil)
        manualLanguage = manual
        tableNames = tables
        columnNames = columns.isEmpty ? ["*"] : columns
        searchTexts = search
        whereTexts = filters
        orderFields = order
        ignoreCase = seen.contains("-i")
        exact = seen.contains("-e")
        compact = seen.contains("-f")
        rowLimit = limit
        busyTimeout = timeout
        nonEmpty = seen.contains("--non-empty")
    }

    private static let shellDefaults = Arguments(
        action: .shell,
        configurationPath: nil,
        databasePath: nil,
        permanentConfigurationPath: nil,
        readOnly: nil,
        manualLanguage: nil,
        tableNames: [],
        columnNames: ["*"],
        searchTexts: [],
        whereTexts: [],
        orderFields: [],
        ignoreCase: false,
        exact: false,
        compact: false,
        rowLimit: nil,
        busyTimeout: nil
    )

    private static let helpDefaults = Arguments(
        action: .help,
        configurationPath: nil,
        databasePath: nil,
        permanentConfigurationPath: nil,
        readOnly: nil,
        manualLanguage: nil,
        tableNames: [],
        columnNames: [],
        searchTexts: [],
        whereTexts: [],
        orderFields: [],
        ignoreCase: false,
        exact: false,
        compact: false,
        rowLimit: nil,
        busyTimeout: nil
    )

    private init(
        action: Action,
        configurationPath: String?,
        databasePath: String?,
        permanentConfigurationPath: String?,
        readOnly: Bool?,
        manualLanguage: String?,
        tableNames: [String],
        columnNames: [String],
        searchTexts: [String],
        whereTexts: [String],
        orderFields: [String],
        ignoreCase: Bool,
        exact: Bool,
        compact: Bool,
        rowLimit: Int?,
        busyTimeout: Int32?
    ) {
        self.action = action
        self.configurationPath = configurationPath
        self.databasePath = databasePath
        self.permanentConfigurationPath = permanentConfigurationPath
        self.readOnly = readOnly
        self.manualLanguage = manualLanguage
        self.tableNames = tableNames
        self.columnNames = columnNames
        self.searchTexts = searchTexts
        self.whereTexts = whereTexts
        self.orderFields = orderFields
        self.ignoreCase = ignoreCase
        self.exact = exact
        self.compact = compact
        self.rowLimit = rowLimit
        self.busyTimeout = busyTimeout
    }

    private static func expandClusters(_ values: [String]) throws -> [String] {
        let groups: [Character: String] = [
            "r": "connection", "w": "connection",
            "i": "search", "e": "search",
            "f": "format", "h": "help"
        ]
        var expanded: [String] = []
        for value in values {
            guard value.hasPrefix("-"), !value.hasPrefix("--"), value.count > 2, value != "-db" else {
                expanded.append(value)
                continue
            }
            let letters = Array(value.dropFirst())
            var seenGroups = Set<String>()
            var flags: [String] = []
            for letter in letters {
                guard let group = groups[letter] else {
                    throw ArgumentError.invalid("Cannot combine -\(letter) in \(value). Flags with values must stand alone.")
                }
                if letter == "h", letters.count > 1 {
                    throw ArgumentError.invalid("Cannot combine -h with other flags.")
                }
                seenGroups.insert(group)
                flags.append("-\(letter)")
            }
            guard seenGroups.count == 1 else {
                throw ArgumentError.invalid("Cannot combine flags from different groups: \(value).")
            }
            if flags.contains("-r"), flags.contains("-w") {
                throw ArgumentError.invalid("Choose either -r or -w, not both.")
            }
            expanded.append(contentsOf: flags)
        }
        return expanded
    }
}
