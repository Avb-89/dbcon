//
//  SearchEpisodes.swift
//  dbcon
//
//  Created by SITIS on 11/16/26.
//

import Foundation

enum SearchEpisodes {
    struct Evidence {
        let condition: Int
        let query: String
        let path: String
        let hit: SearchText.Hit
        let quality: Int
    }

    struct Record {
        let key: [String: Any]
        let group: [String: Any]
        let groupID: Data
        let ordinal: Int
        let texts: [SearchFields.Value]
        let evidence: [Evidence]
        let excluded: Bool
        let metadata: [String: Any]
        let time: [String: Any]?
        let seconds: Double?
    }

    struct Candidate {
        let result: [String: Any]
        let groupID: Data
        let score: Int
        let sequence: Int
        let endSequence: Int
    }

    struct Collector {
        let conditionCount: Int
        let window: Int
        let gap: Double?
        let capacity: Int
        let snippetSize: Int
        let relevance: Bool
        let perGroup: Int
        var ring: [Record] = []
        var candidates: [Candidate] = []
        var matchedWindows = 0

        func better(_ left: Candidate, _ right: Candidate) -> Bool {
            if relevance, left.score != right.score { return left.score > right.score }
            if left.sequence != right.sequence { return left.sequence < right.sequence }
            return left.endSequence < right.endSequence
        }

        mutating func add(_ record: Record) {
            if record.excluded { ring.removeAll(keepingCapacity: true); return }
            if let previous = ring.last {
                if previous.groupID != record.groupID { ring.removeAll(keepingCapacity: true) }
                else if let gap, let left = previous.seconds, let right = record.seconds, abs(right - left) > gap { ring.removeAll(keepingCapacity: true) }
            }
            ring.append(record)
            if ring.count > window { ring.removeFirst() }
            guard !record.evidence.isEmpty else { return }
            var covered = Set<Int>()
            var lowerBound: Int?
            for index in ring.indices.reversed() {
                covered.formUnion(ring[index].evidence.map(\.condition))
                if covered.count == conditionCount { lowerBound = index; break }
            }
            guard let lowerBound else { return }
            let rows = ring[lowerBound...].filter { !$0.evidence.isEmpty }
            guard let first = rows.first, let last = rows.last else { return }
            var best: [Int: (Record, Evidence)] = [:]
            for row in rows {
                for evidence in row.evidence {
                    if evidence.quality > (best[evidence.condition]?.1.quality ?? 0) { best[evidence.condition] = (row, evidence) }
                }
            }
            guard best.count == conditionCount else { return }
            matchedWindows += 1
            let span = last.ordinal - first.ordinal
            let quality = best.values.reduce(0) { $0 + $1.1.quality }
            var score = conditionCount * 1000 + quality + max(0, 100 - span * 10)
            if rows.count == 1 {
                let paths = Dictionary(grouping: best.values.map { $0.1 }, by: \.path)
                for hits in paths.values where hits.count > 1 {
                    let starts = hits.map { $0.hit.start }
                    score += max(0, 100 - ((starts.max() ?? 0) - (starts.min() ?? 0)))
                }
            }
            let proof = best.keys.sorted().compactMap { index -> [String: Any]? in
                guard let (row, evidence) = best[index] else { return nil }
                return ["condition": index + 1, "query": evidence.query, "key": row.key,
                        "field": evidence.path, "method": evidence.hit.method,
                        "start": evidence.hit.start, "end": evidence.hit.end, "quality": evidence.quality]
            }
            let messages = rows.map { row -> [String: Any] in
                var snippets: [String: Any] = [:]
                for value in row.texts {
                    let hits = row.evidence.filter { $0.path == value.path }
                    if let hit = hits.max(by: { $0.quality < $1.quality }) {
                        snippets[value.path] = SearchText(value.text, options: SearchText.Options()).snippet(around: hit.hit, characters: snippetSize)
                    }
                }
                var output: [String: Any] = ["key": row.key, "row_position": row.ordinal, "snippets": snippets]
                if !row.metadata.isEmpty { output["metadata"] = row.metadata }
                if let time = row.time { output["time"] = time }
                return output
            }
            let result: [String: Any] = ["key": first.key, "end_key": last.key, "group": first.group,
                                        "score": score, "conditions_matched": best.count,
                                        "span_rows": span + 1, "evidence": proof, "messages": messages]
            let candidate = Candidate(result: result, groupID: first.groupID, score: score, sequence: first.ordinal, endSequence: last.ordinal)
            candidates.append(candidate)
            candidates.sort(by: better)
            if perGroup > 0 {
                var counts: [Data: Int] = [:]
                candidates = candidates.filter { item in
                    counts[item.groupID, default: 0] += 1
                    return counts[item.groupID, default: 0] <= perGroup
                }
            }
            if candidates.count > capacity { candidates.removeLast() }
        }
    }
}
