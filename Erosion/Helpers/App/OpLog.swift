//
//  OpLog.swift
//  Erosion
//
//  轻量操作日志：所有耗时动作（拉容器 / 边界探测 / 地址扫描）都往
//  Documents/op-log.json 追加一条，电脑端通过 /report 取走，后台按时间线展示。
//

import Foundation

enum OpLog {
    static let maxEntries = 300

    static var url: URL {
        URL.documentsDirectory.appendingPathComponent("op-log.json")
    }

    static func append(_ kind: String, _ status: String, _ message: String) {
        var list: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            list = array
        }
        list.append([
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": kind,
            "status": status,
            "message": message,
        ])
        if list.count > maxEntries {
            list.removeFirst(list.count - maxEntries)
        }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: []) {
            try? data.write(to: url)
        }
        print("(op) [\(kind)/\(status)] \(message)")
    }

    static func load(limit: Int = 120) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Array(array.suffix(limit))
    }
}
