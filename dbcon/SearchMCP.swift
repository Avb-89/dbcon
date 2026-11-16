//
//  SearchMCP.swift
//  dbcon
//
//  Created by SITIS on 11/16/26.
//

import Foundation
import CoreFoundation

enum SearchSchema {
    static var tools: [[String: Any]] {
        func text(_ description: String, choices: [String]? = nil, defaultValue: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["type": "string", "minLength": 1, "description": description]
            if let choices { value["enum"] = choices }
            if let defaultValue { value["default"] = defaultValue }
            return value
        }
        func strings(_ description: String, minimum: Int = 0, maximum: Int = 32) -> [String: Any] {
            ["type": "array", "items": ["type": "string", "minLength": 1], "minItems": minimum, "maxItems": maximum, "uniqueItems": true, "description": description]
        }
        func integer(_ description: String, _ value: Int?, _ minimum: Int, _ maximum: Int) -> [String: Any] {
            var property: [String: Any] = ["type": "integer", "minimum": minimum, "maximum": maximum, "description": description]
            if let value { property["default"] = value }
            return property
        }
        func boolean(_ description: String, _ value: Bool = false) -> [String: Any] {
            ["type": "boolean", "default": value, "description": description]
        }
        var common: [String: Any] = [
            "table": text("One existing literal table name."),
            "key_columns": strings("Required literal columns forming a unique non-NULL key across the table, verified at runtime. Returned unchanged for exact retrieval. No wildcard or JSON paths.", minimum: 1),
            "where": strings("AND structured filters using the same grammar as read_rows: comparisons, AND/OR, parentheses, IS NULL/IS NOT NULL. No LIKE, IN, SQL functions or arbitrary SQL."),
            "metadata_columns": strings("Extra fields returned unchanged. Default none. Existing columns or column:$.path; no wildcard. Large values may exceed max_bytes."),
            "element_types": strings("Optional exact allowed types for wildcard array elements, such as text. Applies only to [*] selectors, not ordinary fields. No inferred types; default all elements."),
            "element_type_field": text("Literal property name containing each array element's type.", defaultValue: "type"),
            "order_by": strings("Existing fields with optional ASC/DESC, same syntax as read_rows. Key columns are appended as stable tie-breakers. No automatic date detection."),
            "time_column": text("Optional timestamp field returned as raw and formatted metadata; requires time_unit. Filtering and ordering still use raw values via where/order_by."),
            "time_unit": text("Required with time_column. ISO-8601 values must include Z or an explicit offset.", choices: ["seconds", "milliseconds", "iso8601"]),
            "time_zone": text("IANA time zone for formatted metadata; requires time_column. Does not change raw filtering or sorting.", defaultValue: "UTC"),
            "snippet_chars": integer("Maximum original Swift Characters per field excerpt; offsets are zero-based Character offsets, end-exclusive, not bytes or tokens.", 240, 16, 4000),
            "max_bytes": integer("Maximum UTF-8 bytes of the entire structured result, including metadata. Not a token limit; MCP text/structured envelopes add overhead. If a result cannot fit alone, returns an explicit error.", 16000, 1024, 1000000)
        ]
        var search = common
        search.merge([
            "search_columns": strings("Text fields, column:$.path or one array expansion such as data:$.content[*].text. Expanded paths report actual indices. Only strings are searched; numbers, NULL and BLOBs are ignored.", minimum: 1),
            "search": strings("Literal conditions, not SQL or field=value. Each item is one substring/word/phrase; split words into separate items for all/any. At least one search, required_groups or phrases condition is required."),
            "phrases": strings("Additional phrases, all required regardless of mode. Exact normalized text with word boundaries; never fuzzy, stemmed or transliterated."),
            "required_groups": strings("All groups are mandatory. Each string lists literal alternatives separated by |, e.g. flag|parameter|argument. No automatic synonyms. Groups can match different rows only with window_rows > 1."),
            "exclude": strings("Reject a row containing any of these normalized literal substrings in any search field and break the episode at that row."),
            "mode": text("Combine search entries across fields. Phrases remain mandatory.", choices: ["all", "any"], defaultValue: "all"),
            "match": text("substring: inside a value; word/phrase: boundary-delimited literal text; whole: entire normalized value. No approximate matching.", choices: ["substring", "word", "phrase", "whole"], defaultValue: "substring"),
            "ignore_case": boolean("Unicode case-insensitive matching for search, phrases and exclusions. Does not affect where/order_by."),
            "normalize_space": boolean("Collapse runs of whitespace for matching only. Excerpts retain original text.", true),
            "fold_yo": boolean("Treat Russian ё/е and Ё/Е as equivalent for matching only."),
            "priority_columns": strings("Subset of search_columns receiving twice the field score. Default none."),
            "group_by": strings("Explicit partition for neighboring episodes. Groups are traversed in ascending group-field order, then order_by/key. NULL groups never combine rows. Does not infer conversation boundaries."),
            "per_group": integer("Maximum candidate episodes per group; default 1 avoids repeated results from one conversation. 0 removes this cap without merging independent episodes. With no group_by every source row is its own group.", 1, 0, 100),
            "window_rows": integer("Maximum eligible text rows in one local episode. Above 1 requires group_by and order_by. Technical rows with no selected text do not count. per_group selects the best episodes; multiple returned episodes can overlap.", 1, 1, 50),
            "max_gap_seconds": integer("Optional maximum time gap between adjacent eligible rows; omitted means no time-gap limit. Requires window_rows > 1 and numeric time_column with seconds/milliseconds units.", nil, 1, 604800),
            "sort": text("relevance: descending explainable score; fields: traversal order, requiring order_by. Ties use group fields, order_by and keys. No inferred relevance or dates.", choices: ["relevance", "fields"], defaultValue: "relevance"),
            "limit": integer("Maximum ranked candidate episodes after the per_group cap, not raw matching rows.", 10, 1, 100),
            "offset": integer("Skip this many ranked candidates. Continue using next_offset; offset_limit_reached requires narrower where filters. No snapshot persists across calls, so concurrent changes can shift pages.", 0, 0, 10000)
        ], uniquingKeysWith: { _, new in new })
        common.merge([
            "anchor_where": strings("AND filters identifying exactly one anchor. Neighbor mode: within where. Related mode: source_table only, independent of target where. Pass exact key values; quote SQL text literals.", minimum: 1),
            "text_columns": strings("Text fields, JSON paths or one [*] expansion, using the same element type filters as search_rows. Rows with no selected text are excluded before counting neighbors.", minimum: 1),
            "full": boolean("Return selected text in full instead of excerpts. max_bytes still applies; an oversized first row is an error, not silent truncation."),
            "before": integer("Number of rows preceding the anchor in order_by. Requires order_by unless source_field/related_field selects related-table mode.", 2, 0, 50),
            "after": integer("Number of rows following the anchor in order_by.", 2, 0, 50),
            "source_table": text("Optional existing source table for a cross-table relation. Default table. Requires source_field and related_field."),
            "source_field": text("Scalar field read from the uniquely selected source row. When supplied, anchor_where selects source_table and where filters target table only."),
            "related_field": text("Field in table compared by SQLite equality to source_field. Paired with source_field; NULL is rejected. Related mode returns ordered rows, not neighbors."),
            "limit": integer("Maximum returned rows in either mode; neighbor mode is also bounded by before/after.", 10, 1, 100),
            "offset": integer("Skip this many rows in the selected context window or relation; continue using next_offset. offset_limit_reached requires narrower filters. Concurrent changes can shift pages.", 0, 0, 10000)
        ], uniquingKeysWith: { _, new in new })
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
        }
        return [
            tool("search_rows", "Find local episodes satisfying explicit groups of literal conditions. Returns exact keys, evidence and original excerpts, not full chats. Optional cross-row matching needs an explicit group and bounded window/order. Scans without indexes or writes; no natural-language understanding. Same engine as CLI/shell. Read originals using read_context or read_rows.", search, ["table", "key_columns", "search_columns"]),
            tool("read_context", "Read bounded neighboring rows around one exact anchor, or ordered related-table rows using an explicit equality relation. No assumed application schema, no inferred chat boundaries, no writes. Excerpts are from the start of each field, with explicit truncation. where must scope neighbors to the intended conversation/project. Use read_rows for full values.", common, ["table", "key_columns", "anchor_where", "text_columns"])
        ]
    }

    static func validate(_ arguments: [String: Any], tool: String) throws {
        guard let definition = tools.first(where: { $0["name"] as? String == tool }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: [String: Any]],
              let required = schema["required"] as? [String],
              Set(arguments.keys).isSubset(of: Set(properties.keys)), required.allSatisfy({ arguments[$0] != nil }) else { throw SearchSupport.fail(Errors.Search.cli) }
        for (key, value) in arguments {
            let property = properties[key] ?? [:]
            var valid = false
            switch property["type"] as? String {
            case "string":
                if let text = value as? String {
                    valid = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains("\0")
                    if let choices = property["enum"] as? [String] { valid = valid && choices.contains(text) }
                }
            case "array":
                if let items = value as? [String] {
                    valid = items.count >= (property["minItems"] as? Int ?? 0) && items.count <= (property["maxItems"] as? Int ?? 32)
                        && Set(items).count == items.count && items.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0") }
                }
            case "integer":
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    valid = number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
                        && number.compare(NSNumber(value: property["minimum"] as? Int ?? 0)) != .orderedAscending
                        && number.compare(NSNumber(value: property["maximum"] as? Int ?? Int.max)) != .orderedDescending
                }
            case "boolean":
                if let number = value as? NSNumber { valid = CFGetTypeID(number) == CFBooleanGetTypeID() }
            default: break
            }
            guard valid else { throw SearchSupport.fail(Errors.RPC.invalidArgument(key, expected: property["type"] as? String)) }
        }
    }
}

extension MCP {
    static var searchTools: [[String: Any]] { SearchSchema.tools }
}
