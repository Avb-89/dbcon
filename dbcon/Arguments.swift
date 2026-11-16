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
        case insert
        case update
        case delete
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
    var valueExpressions: String?
    var assignments: String?
    var searchCommand: SearchCLI.Command? = nil

    init(_ values: [String], inShell: Bool = false) throws {
        if SearchCLI.isAdvanced(values) {
            self = try SearchCLI.parse(values, inShell: inShell)
            return
        }
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
        var valueExpressions: String?
        var assignments: String?

        func takeNames(_ flag: String) throws -> [String] {
            var names: [String] = []
            while index < values.count, !values[index].hasPrefix("-") {
                let name = values[index]
                guard !name.isEmpty, !name.contains("\0") else {
                    throw ArgumentError.invalid(Errors.CLI.invalidNames)
                }
                let parts = name.split(separator: ",", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !parts.isEmpty else {
                    throw ArgumentError.invalid(Errors.CLI.emptyNames)
                }
                names.append(contentsOf: parts)
                index += 1
            }
            guard Set(names).count == names.count else {
                throw ArgumentError.invalid(Errors.CLI.duplicateNames(flag))
            }
            guard !names.contains("*") || names.count == 1 else {
                throw ArgumentError.invalid(Errors.CLI.wildcardNames(flag))
            }
            return names
        }

        while index < values.count {
            let flag = values[index]
            let supported = [
                "--config", "--set-config", "--mcp", "--db", "--tables", "--table", "--column", "--columns", "--read",
                "--search", "--where", "--order-by", "--man", "--help", "--timeout", "-r", "-w", "-i", "-e", "-f", "-h",
                "-t", "-c", "-n", "-s", "--count", "--non-empty", "-p",
                "--insert", "--update", "--delete", "--values", "--set"
            ]
            let option = ["-db": "--db", "--eq": "-e", "--equal": "-e", "--sort": "--order-by", "-I": "--insert", "-u": "--update"][flag] ?? flag
            guard supported.contains(option) else {
                throw ArgumentError.invalid(Errors.CLI.unknownArgument(flag))
            }
            if inShell, ["--db", "--config", "--set-config", "--mcp", "--timeout", "-r", "-w"].contains(option) {
                throw ArgumentError.invalid(Errors.CLI.startupOption(flag))
            }
            let seenKey = ["-t": "--table", "-c": "--column", "-s": "--search", "-p": "--non-empty"][option] ?? option
            let repeatable = ["--search", "--where", "--order-by"]
            guard seen.insert(seenKey).inserted || repeatable.contains(seenKey) else {
                throw ArgumentError.invalid(Errors.CLI.duplicateOption(flag))
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
            case "--set-config", "--mcp", "--read", "--columns", "--count", "--non-empty", "-p", "-i", "-e", "-f", "-h", "--help", "--insert", "--update", "--delete":
                break
            case "--values", "--set":
                guard index < values.count,
                      !values[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !values[index].contains("\0") else {
                    throw ArgumentError.invalid(Errors.CLI.sqlListRequired(flag))
                }
                if option == "--values" { valueExpressions = values[index] }
                else { assignments = values[index] }
                index += 1
            case "--search", "-s":
                guard index < values.count, !values[index].hasPrefix("-"),
                      !values[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !values[index].contains("\0") else {
                    throw ArgumentError.invalid(Errors.CLI.textRequired(flag))
                }
                search.append(values[index])
                index += 1
            case "--where", "--order-by":
                guard index < values.count, !values[index].hasPrefix("-"),
                      !values[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !values[index].contains("\0") else {
                    throw ArgumentError.invalid(Errors.CLI.valueRequired(flag))
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
                    throw ArgumentError.invalid(Errors.CLI.pathRequired(flag))
                }
                if option == "--config" {
                    config = values[index]
                } else {
                    database = values[index]
                }
                index += 1
            case "--timeout":
                guard index < values.count, let value = Int32(values[index]), value >= 1000 else {
                    throw ArgumentError.invalid(Errors.CLI.timeoutRequired)
                }
                timeout = value
                index += 1
            case "-n":
                guard index < values.count, let value = Int(values[index]), value >= 1 else {
                    throw ArgumentError.invalid(Errors.CLI.limitRequired)
                }
                limit = value
                index += 1
            case "--tables", "--table", "-t", "--column", "-c":
                let names = try takeNames(flag)
                if option == "--column" || option == "-c" {
                    guard !names.isEmpty else {
                        throw ArgumentError.invalid(Errors.CLI.columnsRequired(flag))
                    }
                    columns = names
                } else {
                    guard option == "--tables" || !names.isEmpty else {
                        throw ArgumentError.invalid(Errors.CLI.tablesRequired(flag))
                    }
                    tables = names
                }
            default:
                break
            }
        }

        guard !(seen.contains("-r") && seen.contains("-w")) else {
            throw ArgumentError.invalid(Errors.CLI.accessConflict)
        }
        guard !(seen.contains("--tables") && seen.contains("--table")) else {
            throw ArgumentError.invalid(Errors.CLI.tableConflict)
        }
        if seen.contains("--columns") {
            guard !seen.contains("--column"), !seen.contains("--read"), !seen.contains("--where"), !seen.contains("--order-by"), search.isEmpty else {
                throw ArgumentError.invalid(Errors.CLI.structureConflict)
            }
        }
        if seen.contains("--column"), tables.isEmpty {
            throw ArgumentError.invalid(Errors.CLI.columnsNeedTable)
        }
        if seen.contains("--non-empty"), !seen.contains("--count") {
            throw ArgumentError.invalid(Errors.CLI.nonEmptyNeedsCount)
        }
        if seen.contains("--count") {
            guard !tables.isEmpty else {
                throw ArgumentError.invalid(Errors.CLI.countNeedsTable)
            }
            guard !seen.contains("--order-by") else {
                throw ArgumentError.invalid(Errors.CLI.sortNeedsRead)
            }
            guard seen.isDisjoint(with: ["--read", "--columns", "-f", "-n"]) else {
                throw ArgumentError.invalid(Errors.CLI.countConflict)
            }
            guard !seen.contains("--column") || seen.contains("--non-empty") || !search.isEmpty else {
                throw ArgumentError.invalid(Errors.CLI.countColumns)
            }
        }

        let writeFlags = seen.intersection(["--insert", "--update", "--delete"])
        guard writeFlags.count <= 1 else {
            throw ArgumentError.invalid(Errors.CLI.writeConflict)
        }
        if !writeFlags.isEmpty {
            guard tables.count == 1, tables != ["*"] else {
                throw ArgumentError.invalid(Errors.CLI.writeTable)
            }
            var allowed: Set<String> = ["--db", "--config", "--timeout", "-r", "-w", "--table"]
            allowed.formUnion(writeFlags)
            if seen.contains("--insert") {
                allowed.formUnion(["--column", "--values"])
                guard valueExpressions != nil else { throw ArgumentError.invalid(Errors.CLI.insertValues) }
            } else if seen.contains("--update") {
                allowed.formUnion(["--set", "--where"])
                guard assignments != nil else { throw ArgumentError.invalid(Errors.CLI.updateSet) }
            } else {
                allowed.insert("--where")
            }
            guard seen.isSubset(of: allowed) else {
                throw ArgumentError.invalid(Errors.CLI.writeOption)
            }
        } else if valueExpressions != nil || assignments != nil {
            throw ArgumentError.invalid(Errors.CLI.writeArguments)
        }

        if search.isEmpty, seen.contains("-i") || seen.contains("-e") {
            throw ArgumentError.invalid(Errors.CLI.searchModesNeedSearch)
        }
        let selected: Action
        if seen.contains("--help") || seen.contains("-h") {
            guard seen.subtracting(["--help", "-h"]).isEmpty else {
                throw ArgumentError.invalid(Errors.CLI.helpAlone)
            }
            selected = .help
        } else if manual != nil {
            guard seen == Set(["--man"]) else {
                throw ArgumentError.invalid(Errors.CLI.manualAlone)
            }
            selected = .manual
        } else if seen.contains("--set-config") {
            guard seen == Set(["--set-config"]) else {
                throw ArgumentError.invalid(Errors.CLI.configAlone)
            }
            selected = .setConfiguration
        } else if seen.contains("--mcp") {
            guard seen.isSubset(of: ["--mcp", "--db", "--config", "--timeout", "-r", "-w"]) else {
                throw ArgumentError.invalid(Errors.CLI.mcpOptions)
            }
            guard seen.contains("-r") || seen.contains("-w") else {
                throw ArgumentError.invalid(Errors.CLI.mcpModeRequired)
            }
            selected = .mcp
        } else if seen.contains("--insert") {
            selected = .insert
        } else if seen.contains("--update") {
            selected = .update
        } else if seen.contains("--delete") {
            selected = .delete
        } else if seen.contains("--count") {
            selected = .count
        } else if !search.isEmpty {
            guard !seen.contains("--read") else {
                throw ArgumentError.invalid(Errors.CLI.searchReadConflict)
            }
            guard !tables.isEmpty else {
                throw ArgumentError.invalid(Errors.CLI.searchNeedsTable)
            }
            selected = .search
        } else if seen.contains("-i") || seen.contains("-e") {
            throw ArgumentError.invalid(Errors.CLI.caseModesNeedSearch)
        } else if seen.contains("--columns") {
            guard !tables.isEmpty else {
                throw ArgumentError.invalid(Errors.CLI.structureNeedsTable)
            }
            selected = .columns
        } else if seen.contains("--tables"), tables.isEmpty {
            guard !seen.contains("--read"), !seen.contains("-f"), limit == nil else {
                throw ArgumentError.invalid(Errors.CLI.readTableNames)
            }
            selected = .tables
        } else if seen.contains("--read") || !tables.isEmpty || seen.contains("-f") || limit != nil || seen.contains("--where") || seen.contains("--order-by") {
            guard !tables.isEmpty else {
                throw ArgumentError.invalid(Errors.CLI.readNeedsTable)
            }
            selected = .read
        } else {
            selected = .shell
        }

        if seen.contains("--where") || seen.contains("--order-by"), selected != .read, selected != .search, selected != .count, selected != .update, selected != .delete {
            throw ArgumentError.invalid(Errors.CLI.filterAction)
        }
        if seen.contains("--order-by"), selected == .count {
            throw ArgumentError.invalid(Errors.CLI.sortNeedsRead)
        }
        if seen.contains("-f"), selected != .read, selected != .search {
            throw ArgumentError.invalid(Errors.CLI.compactNeedsRead)
        }
        if limit != nil, selected != .read, selected != .search {
            throw ArgumentError.invalid(Errors.CLI.limitNeedsRead)
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
        self.valueExpressions = valueExpressions
        self.assignments = assignments
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
        var sqlValueExpected = false
        for value in values {
            if sqlValueExpected {
                expanded.append(value)
                sqlValueExpected = false
                continue
            }
            if value == "--values" || value == "--set" {
                expanded.append(value)
                sqlValueExpected = true
                continue
            }
            guard value.hasPrefix("-"), !value.hasPrefix("--"), value.count > 2, value != "-db" else {
                expanded.append(value)
                continue
            }
            let letters = Array(value.dropFirst())
            var seenGroups = Set<String>()
            var flags: [String] = []
            for letter in letters {
                guard let group = groups[letter] else {
                    throw ArgumentError.invalid(Errors.CLI.clusterValue(letter, in: value))
                }
                if letter == "h", letters.count > 1 {
                    throw ArgumentError.invalid(Errors.CLI.clusterHelp)
                }
                seenGroups.insert(group)
                flags.append("-\(letter)")
            }
            guard seenGroups.count == 1 else {
                throw ArgumentError.invalid(Errors.CLI.clusterGroups(value))
            }
            if flags.contains("-r"), flags.contains("-w") {
                throw ArgumentError.invalid(Errors.CLI.accessConflict)
            }
            expanded.append(contentsOf: flags)
        }
        return expanded
    }
}
