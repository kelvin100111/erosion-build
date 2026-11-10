//
//  KeywordScan.swift
//  Erosion
//
//  机内关键词扫描：遍历给定容器路径下的文本类文件，搜关键词，
//  命中写入 Documents/scan-result.json（只返回路径+片段，不搬文件）。
//

import Foundation

enum KeywordScan {
    static let maxFileSize = 4 * 1024 * 1024
    static let textExtensions: Set<String> = [
        "json", "txt", "plist", "log", "md", "csv", "xml", "html", "js", "sqlite", "sqlite3", "db", "dat", "bin"
    ]

    struct Config {
        let roots: [String]
        let keywords: [String]
    }

    static func loadConfig() -> Config? {
        let url = URL.documentsDirectory.appendingPathComponent("scan-config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String],
              let keywords = object["keywords"] as? [String] else {
            return nil
        }
        return Config(roots: roots, keywords: keywords)
    }

    static func run(group: String) {
        guard let config = loadConfig() else {
            print("(scan) 缺少 scan-config.json")
            return
        }

        let fm = FileManager.default
        var results: [[String: Any]] = []
        var scanned = 0
        var started = Date()

        for root in config.roots {
            let handle = worse_query(root, group, false, false)
            let handleAlt = handle < 0 ? worse_query(root, group, true, false) : handle
            guard handleAlt >= 0 else {
                print("(scan) grant 失败 \(root)")
                continue
            }

            let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            )

            while let url = enumerator?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let size = values?.fileSize ?? 0
                if size <= 0 || size > maxFileSize { continue }
                let ext = url.pathExtension.lowercased()
                if !textExtensions.contains(ext) && ext != "" { continue }

                guard let data = try? Data(contentsOf: url) else { continue }
                scanned += 1
                if scanned % 5000 == 0 {
                    print("(scan) 已扫描 \(scanned) 个文件")
                }

                for keyword in config.keywords {
                    guard let needle = keyword.data(using: .utf8) else { continue }
                    if let range = data.range(of: needle) {
                        let start = max(0, range.lowerBound - 80)
                        let end = min(data.count, range.upperBound + 160)
                        let snippetData = data.subdata(in: start..<end)
                        let snippet = String(data: snippetData, encoding: .utf8)
                            ?? String(data: snippetData, encoding: .isoLatin1)
                            ?? ""
                        results.append([
                            "root": root,
                            "path": url.path,
                            "size": size,
                            "keyword": keyword,
                            "snippet": snippet
                        ])
                        break
                    }
                }
                if results.count >= 800 { break }
            }
            worse_query_release(handleAlt)
            print("(scan) 完成根目录 \(root) 用时 \(Int(Date().timeIntervalSince(started)))s")
            started = Date()
        }

        let payload: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "scanned": scanned,
            "hits": results
        ]
        let url = URL.documentsDirectory.appendingPathComponent("scan-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        print("(scan) 完成，扫 \(scanned) 个文件，命中 \(results.count)")
    }
}
