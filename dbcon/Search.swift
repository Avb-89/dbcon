//
//  Search.swift
//  dbcon
//
//  Created by SITIS on 11/16/26.
//

import Foundation

enum Search {
    static func run(_ arguments: [String: Any], inspector: DatabaseInspector) throws -> [String: Any] {
        try SearchSchema.validate(arguments, tool: "search_rows")
        return try SearchSupport.snapshot(inspector) { try perform(arguments, inspector: inspector) }
    }

    private static func perform(_ a: [String: Any], inspector: DatabaseInspector) throws -> [String: Any] {
        let table = a["table"] as? String ?? ""
        let available = try SearchSupport.columns(table, inspector: inspector)
        let columns = a["search_columns"] as? [String] ?? []
        let keys = a["key_columns"] as? [String] ?? []
        let metadata = a["metadata_columns"] as? [String] ?? []
        let groups = a["group_by"] as? [String] ?? []
        let priority = a["priority_columns"] as? [String] ?? []
        let terms = a["search"] as? [String] ?? []
        let phrases = a["phrases"] as? [String] ?? []
        let excluded = a["exclude"] as? [String] ?? []
        let mode = a["mode"] as? String ?? "all"
        let sort = a["sort"] as? String ?? "relevance"
        let order = a["order_by"] as? [String] ?? []
        let limit = (a["limit"] as? NSNumber)?.intValue ?? 10
        let offset = (a["offset"] as? NSNumber)?.intValue ?? 0
        let maximum = (a["max_bytes"] as? NSNumber)?.intValue ?? 16000
        let snippetSize = (a["snippet_chars"] as? NSNumber)?.intValue ?? 240
        let window = (a["window_rows"] as? NSNumber)?.intValue ?? 1
        let gap = (a["max_gap_seconds"] as? NSNumber)?.doubleValue
        let elementTypes = a["element_types"] as? [String] ?? []
        let typeField = a["element_type_field"] as? String ?? "type"
        var options = SearchText.Options()
        options.ignoreCase = a["ignore_case"] as? Bool ?? false
        options.normalizeSpace = a["normalize_space"] as? Bool ?? true
        options.foldYo = a["fold_yo"] as? Bool ?? false
        options.match = a["match"] as? String ?? "substring"
        guard !columns.isEmpty, Set(columns).count == columns.count, !columns.contains("*") else { throw SearchSupport.fail(Errors.Search.fields) }
        _ = try SearchFields.projection(columns, available: available)
        try SearchSupport.fields(metadata, available: available)
        try SearchSupport.fields(groups, available: available)
        guard Set(priority).isSubset(of: Set(columns)) else { throw SearchSupport.fail(Errors.Search.fields) }
        try SearchSupport.keys(keys, table: table, available: available, inspector: inspector)
        try SearchSupport.validateTime(a, available: available)
        var conditions = mode == "any" && !terms.isEmpty ? [terms] : terms.map { [$0] }
        let required = a["required_groups"] as? [String] ?? []
        for group in required {
            let alternatives = group.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !alternatives.contains(""), alternatives.count <= 32 else { throw SearchSupport.fail(Errors.Search.alternatives) }
            conditions.append(alternatives)
        }
        let phraseStart = conditions.count
        conditions += phrases.map { [$0] }
        guard !conditions.isEmpty, conditions.count <= 32,
              (conditions.flatMap { $0 } + excluded).allSatisfy({ !SearchText.normalized($0, options: options).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw SearchSupport.fail(Errors.Search.terms) }
        guard window == 1 || (!groups.isEmpty && !order.isEmpty),
              gap == nil || (window > 1 && a["time_column"] != nil && ["seconds", "milliseconds"].contains(a["time_unit"] as? String ?? "")) else { throw SearchSupport.fail(Errors.Search.episode) }
        guard sort != "fields" || !order.isEmpty else { throw SearchSupport.fail(Errors.Search.order) }
        let timeFields = (a["time_column"] as? String).map { [$0] } ?? []
        let selected = Array(Set(columns + keys + metadata + groups + timeFields)).sorted()
        let projection = try SearchFields.projection(selected, available: available)
        let query = try QuerySQL(columns: keys, available: available, terms: [], conditions: a["where"] as? [String] ?? [], orderFields: groups.map { "\($0) ASC" } + order + keys.map { "\($0) ASC" }, ignoreCase: false, exact: false)
        var scanned = 0
        var matched = 0
        var eligible = 0
        let perGroup = (a["per_group"] as? NSNumber)?.intValue ?? 1
        var collector = SearchEpisodes.Collector(conditionCount: conditions.count, window: window, gap: gap, capacity: offset + limit + 1, snippetSize: snippetSize, relevance: sort == "relevance", perGroup: perGroup)
        try SearchSupport.stream("SELECT \(projection) FROM \(QuerySQL.quote(table)) WHERE \(query.filter)\(query.orderClause)", parameters: query.parameters, inspector: inspector) { row in
            scanned += 1
            let values = try SearchFields.values(columns, row: row, elementTypes: elementTypes, typeField: typeField, literalFields: available)
            guard !values.isEmpty else { return }
            eligible += 1
            let texts = values.map { ($0, SearchText($0.text, options: options)) }
            let rejected = excluded.contains { term in texts.contains { $0.1.find(term, literal: true) != nil } }
            var evidence: [SearchEpisodes.Evidence] = []
            for (index, alternatives) in conditions.enumerated() {
                for (value, text) in texts {
                    var best: SearchEpisodes.Evidence?
                    for term in alternatives {
                        guard let hit = text.find(term, phrase: index >= phraseStart || options.match == "phrase") else { continue }
                        let quality = hit.quality * (priority.contains(value.selector) ? 2 : 1)
                        if quality > (best?.quality ?? 0) { best = .init(condition: index, query: term, path: value.path, hit: hit, quality: quality) }
                    }
                    if let best { evidence.append(best) }
                }
            }
            if !evidence.isEmpty && !rejected { matched += 1 }
            let key = SearchSupport.selected(keys, row: row)
            for value in key.values { _ = try SearchSupport.scalar(value) }
            let grouping = SearchSupport.selected(groups, row: row)
            let groupID = try SearchSupport.identity(groups.isEmpty || grouping.values.contains(where: { $0 is NSNull }) ? ["row": key] : ["group": grouping])
            let time = try SearchSupport.time(a, row: row)
            var seconds: Double?
            if gap != nil, let field = a["time_column"] as? String {
                guard let number = row[field] as? NSNumber, number.doubleValue.isFinite else { throw SearchSupport.fail(Errors.Search.invalidTime) }
                seconds = number.doubleValue / ((a["time_unit"] as? String) == "milliseconds" ? 1000 : 1)
            }
            collector.add(.init(key: key, group: grouping, groupID: groupID, ordinal: eligible, texts: values,
                                    evidence: evidence, excluded: rejected, metadata: SearchSupport.selected(metadata, row: row), time: time, seconds: seconds))
        }
        let more = collector.candidates.count > offset + limit
        let page = collector.candidates.dropFirst(offset).prefix(limit).enumerated().map { index, candidate -> [String: Any] in
            var row = candidate.result
            row["position"] = offset + index + 1
            return row
        }
        return try SearchSupport.bounded([
            "table": table, "scanned_rows": scanned, "eligible_rows": eligible, "matching_source_rows": matched,
            "matched_windows": collector.matchedWindows, "conditions": conditions,
            "limit": limit, "offset": offset, "sort": sort, "window_rows": window, "per_group": perGroup,
            "matching": ["ignore_case": options.ignoreCase, "normalize_space": options.normalizeSpace, "fold_yo": options.foldYo,
                         "match": options.match, "mode": mode]
        ], candidates: page, maximum: maximum, offset: offset, more: more)
    }
}

extension DatabaseInspector {
    func searchTables(tables: [String], columns: [String], queries: [String], conditions: [String] = [], orderFields: [String] = [], ignoreCase: Bool, exact: Bool, compact: Bool = false, rowLimit: Int? = nil) throws {
        try registerSearch()
        for table in try selectedTables(tables) {
            let query = try QuerySQL(columns: columns, available: columnNames(table), terms: queries, conditions: conditions, orderFields: orderFields, ignoreCase: ignoreCase, exact: exact)
            let limit = rowLimit.map { " LIMIT \($0)" } ?? ""
            print("\nTABLE: \(table)")
            try dumpRows("SELECT \(query.projection) FROM \(Self.quotedIdentifier(table)) WHERE \(query.filter)\(query.orderClause)\(limit)", compact: compact, parameters: query.parameters)
        }
    }
}
