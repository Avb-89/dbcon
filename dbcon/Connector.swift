//
//  Connector.swift
//  dbcon
//
//  Created by SITIS on 11/10/26.
//

import Foundation
import Darwin

@main
struct Connector {
    private struct Configuration: Codable {
        let databasePath: String
        let readOnly: Bool
        let busyTimeoutMilliseconds: Int32
    }

    private enum StartupError: LocalizedError {
        case invalidConfiguration(String)

        var errorDescription: String? {
            switch self {
            case let .invalidConfiguration(message):
                return message
            }
        }
    }

    static func main() {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.action == .help {
                print(Man.help)
                return
            }
            if arguments.action == .manual {
                print(try Man.manual(language: arguments.manualLanguage ?? "en"))
                return
            }

            let directory = try configurationDirectory()
            if arguments.action == .setConfiguration {
                try runConfigurationWizard(directory: directory)
                return
            }

            let configurationURL: URL?
            if let path = arguments.configurationPath {
                configurationURL = fileURL(path)
            } else if arguments.databasePath != nil {
                configurationURL = nil
            } else {
                configurationURL = try defaultConfigurationURL(directory: directory)
            }

            let configuration: Configuration?
            if let configurationURL {
                configuration = try loadConfiguration(configurationURL)
            } else {
                configuration = nil
            }

            let databaseURL: URL
            if let path = arguments.databasePath {
                databaseURL = fileURL(path)
            } else if let configuration, let configurationURL {
                databaseURL = fileURL(configuration.databasePath, relativeTo: configurationURL.deletingLastPathComponent())
            } else {
                throw StartupError.invalidConfiguration(Man.connectionHint)
            }

            let inspector = try DatabaseInspector(
                databasePath: databaseURL.standardizedFileURL.path,
                readOnly: arguments.action == .mcp ? true : (arguments.readOnly ?? configuration?.readOnly ?? true),
                busyTimeoutMilliseconds: arguments.busyTimeout ?? configuration?.busyTimeoutMilliseconds ?? 3000
            )
            switch arguments.action {
            case .help, .setConfiguration, .manual:
                break
            case .mcp:
                try MCP.run(inspector: inspector)
            case .shell:
                try Shell.run(
                    inspector: inspector,
                    readOnly: arguments.readOnly ?? configuration?.readOnly ?? true
                )
            case .tables:
                try inspector.listTables()
            case .columns:
                try inspector.showColumns(tables: arguments.tableNames)
            case .count:
                try inspector.countRows(tables: arguments.tableNames, columns: arguments.columnNames, nonEmpty: arguments.nonEmpty, queries: arguments.searchTexts, conditions: arguments.whereTexts, ignoreCase: arguments.ignoreCase, exact: arguments.exact)
            case .read:
                try inspector.readTables(
                    tables: arguments.tableNames,
                    columns: arguments.columnNames,
                    conditions: arguments.whereTexts,
                    orderFields: arguments.orderFields,
                    compact: arguments.compact,
                    rowLimit: arguments.rowLimit
                )
            case .search:
                try inspector.searchTables(
                    tables: arguments.tableNames,
                    columns: arguments.columnNames,
                    queries: arguments.searchTexts,
                    conditions: arguments.whereTexts,
                    orderFields: arguments.orderFields,
                    ignoreCase: arguments.ignoreCase,
                    exact: arguments.exact,
                    compact: arguments.compact,
                    rowLimit: arguments.rowLimit
                )
            }
        } catch {
            let message = "Error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func configurationDirectory() throws -> URL {
        guard let executable = Bundle.main.executableURL else {
            throw StartupError.invalidConfiguration("Could not determine the executable location.")
        }
        let directory = executable.deletingLastPathComponent()
        let root = directory.lastPathComponent == "bin" ? directory.deletingLastPathComponent() : directory
        return root.appendingPathComponent("conf", isDirectory: true).standardizedFileURL
    }

    private static func fileURL(_ path: String, relativeTo directory: URL? = nil) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if let directory, !(expanded as NSString).isAbsolutePath {
            return directory.appendingPathComponent(expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func loadConfiguration(_ url: URL) throws -> Configuration {
        let configuration: Configuration
        do {
            configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        } catch {
            throw StartupError.invalidConfiguration("Cannot load configuration '\(url.path)': \(error.localizedDescription)")
        }
        guard !configuration.databasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.databasePath.contains("\0"), configuration.databasePath != "Your base" else {
            throw StartupError.invalidConfiguration("Set a valid databasePath in '\(url.path)'.")
        }
        guard configuration.busyTimeoutMilliseconds >= 1000 else {
            throw StartupError.invalidConfiguration("busyTimeoutMilliseconds must be at least 1000 in '\(url.path)'.")
        }
        return configuration
    }

    private static func defaultConfigurationURL(directory: URL) throws -> URL? {
        let settings = directory.appendingPathComponent("settings.ini")
        if FileManager.default.fileExists(atPath: settings.path) {
            let content = try String(contentsOf: settings, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") }
            guard lines.count == 1, let line = lines.first, line.hasPrefix("configPath=") else {
                throw StartupError.invalidConfiguration("Invalid settings file: \(settings.path). Expected configPath=<path>.")
            }
            let path = String(line.dropFirst("configPath=".count))
            guard !path.isEmpty, !path.contains("\0") else {
                throw StartupError.invalidConfiguration("Invalid configPath in '\(settings.path)'.")
            }
            return fileURL(path, relativeTo: directory)
        }
        let fallback = directory.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private static let nothingCreated = "Nothing was created."

    private static func runConfigurationWizard(directory: URL) throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw StartupError.invalidConfiguration("dbcon --set-config requires an interactive terminal.")
        }
        let choice = try chooseConfigurationURL(directory: directory)
        if !choice.create, try useExistingConfiguration(choice.url, directory: directory) {
            return
        }
        let configURL = choice.url
        let databasePath = try askDatabasePath(configURL: configURL)
        let readOnly = try askBool("readOnly [true]: ", defaultValue: true)
        let timeout = try askTimeout("busyTimeoutMilliseconds [3000]: ", defaultValue: 3000)
        let configuration = Configuration(
            databasePath: databasePath,
            readOnly: readOnly,
            busyTimeoutMilliseconds: timeout
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try configurationJSON(configuration).write(to: configURL, options: .atomic)
        try writeSettings(configURL, directory: directory)
        print("Configuration: \(configURL.path)")
        print("Settings: \(directory.appendingPathComponent("settings.ini").path)")
    }

    private static func chooseConfigurationURL(directory: URL) throws -> (url: URL, create: Bool) {
        let defaultURL = directory.appendingPathComponent("config.json")
        guard let answer = ask("Configuration file [/path/to/json/config.json]: ") else {
            throw StartupError.invalidConfiguration(nothingCreated)
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\0"), !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw StartupError.invalidConfiguration("Invalid configuration path.\n\(nothingCreated)")
        }
        let url = trimmed.isEmpty ? defaultURL : fileURL(trimmed)
        if isDirectory(url) {
            throw StartupError.invalidConfiguration("Not a configuration file: \(url.path)\n\(nothingCreated)")
        }
        if trimmed.isEmpty || !FileManager.default.fileExists(atPath: url.path) {
            if !trimmed.isEmpty {
                print("Configuration file was not found: \(url.path)")
            }
            guard try confirmed("Create file? [y/N]: ") else {
                throw StartupError.invalidConfiguration(nothingCreated)
            }
            return (url, true)
        }
        return (url, false)
    }

    private static func useExistingConfiguration(_ url: URL, directory: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        if (try? loadConfiguration(url)) != nil {
            try writeSettings(url, directory: directory)
            print("Default configuration: \(url.path)")
            print("Settings saved: \(directory.appendingPathComponent("settings.ini").path)")
            return true
        }
        print("Cannot load configuration: \(url.path)")
        guard try confirmed("Replace it? [y/n]: ") else {
            throw StartupError.invalidConfiguration(nothingCreated)
        }
        return false
    }

    private static func askDatabasePath(configURL: URL) throws -> String {
        let answer = ask("Database path: ")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = fileURL(answer, relativeTo: configURL.deletingLastPathComponent())
        guard !answer.isEmpty, !answer.contains("\0"), !answer.contains("\n"), !answer.contains("\r"), answer != "Your base",
              !isDirectory(resolved), FileManager.default.fileExists(atPath: resolved.path) else {
            throw StartupError.invalidConfiguration("""
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
            """)
        }
        return answer
    }

    private static func askBool(_ prompt: String, defaultValue: Bool) throws -> Bool {
        while true {
            guard let answer = ask(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw StartupError.invalidConfiguration(nothingCreated)
            }
            if answer.isEmpty {
                return defaultValue
            }
            switch answer.lowercased() {
            case "true", "yes", "y", "1":
                return true
            case "false", "no", "n", "0":
                return false
            default:
                print("Enter true or false.")
            }
        }
    }

    private static func askTimeout(_ prompt: String, defaultValue: Int32) throws -> Int32 {
        while true {
            guard let answer = ask(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw StartupError.invalidConfiguration(nothingCreated)
            }
            if answer.isEmpty {
                return defaultValue
            }
            if let value = Int32(answer), value >= 1000 {
                return value
            }
            print("Enter at least 1000.")
        }
    }

    private static func confirmed(_ prompt: String) throws -> Bool {
        while true {
            guard let answer = ask(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }
            if answer.isEmpty || answer == "n" || answer == "no" {
                return false
            }
            if answer == "y" || answer == "yes" {
                return true
            }
            print("Enter y or n.")
        }
    }

    private static func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func configurationJSON(_ configuration: Configuration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let path = String(decoding: try encoder.encode(configuration.databasePath), as: UTF8.self)
        let text = """
        {
          "databasePath": \(path),
          "readOnly": \(configuration.readOnly),
          "busyTimeoutMilliseconds": \(configuration.busyTimeoutMilliseconds)
        }

        """
        return Data(text.utf8)
    }

    private static func writeSettings(_ url: URL, directory: URL) throws {
        let base = directory.pathComponents
        let target = url.standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(base.count, target.count), base[shared] == target[shared] {
            shared += 1
        }
        let components = Array(repeating: "..", count: base.count - shared) + Array(target.dropFirst(shared))
        let relativePath = components.joined(separator: "/")
        guard !relativePath.isEmpty, !relativePath.contains("\n"), !relativePath.contains("\r") else {
            throw StartupError.invalidConfiguration("Configuration paths must not contain line breaks.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "configPath=\(relativePath)\n".write(
            to: directory.appendingPathComponent("settings.ini"),
            atomically: true,
            encoding: .utf8
        )
    }
}
