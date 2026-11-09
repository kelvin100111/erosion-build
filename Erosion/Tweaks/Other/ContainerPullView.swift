//
//  ContainerPullView.swift
//  Erosion
//
//  把任意 app 的数据容器 / App Group 容器复制进自己的 Documents,
//  再由电脑端 AFC 取走。
//
//  经验:
//  1. worse_query 的 kernel extension 只覆盖容器根目录;
//     /var/mobile/Media 和 /var/mobile/Containers/Data/Application(父目录) 都是 -6
//  2. App Group 容器拿父目录的 extension 就够了 (递归), 不用逐个 grant
//  3. 路径必须显式传, 不能靠 @State —— 后台线程读不到主线程刚排队的赋值
//

import SwiftUI

struct ContainerPullView: View {
    @EnvironmentObject private var mgr: ErosionManager

    @State private var container = "/private/var/mobile/Containers/Data/Application/F443C7AE-3166-4EF3-B633-61D4BA9F4FF7"
    @State private var bundleID = "com.tencent.xin"
    @State private var running = false
    @State private var status = "Idle"
    @State private var fileCount = 0
    @State private var byteCount: Int64 = 0

    private let notesGroup = "/private/var/mobile/Containers/Shared/AppGroup/5FEEE48A-F19D-48C9-B524-9E40BB0875F1"
    private let appGroupRoot = "/private/var/mobile/Containers/Shared/AppGroup"

    private var dest: URL {
        URL.documentsDirectory.appendingPathComponent("Pulled", isDirectory: true)
    }
    private var logURL: URL {
        URL.documentsDirectory.appendingPathComponent("cp-log.txt")
    }

    var body: some View {
        List {
            Section {
                TextField("Container path", text: $container)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.footnote, design: .monospaced))
            } header: {
                HeaderLabel("Target", symbol: "shippingbox")
            } footer: {
                Text("默认是备忘录的 app 容器。App Group 容器用下面的预设按钮。")
            }

            Section {
                Button("备忘录 App Group（group.com.apple.notes）") {
                    start { pullNotesGroup() }
                }
                Button("当前 Target 整个容器") {
                    start { pull(path: container, sub: "", as: "Container") }
                }
                Button("诊断：把各路径的返回码写进 probe.txt") {
                    start { writeProbe() }
                }
            } header: {
                HeaderLabel("Pull", symbol: "arrow.down.doc")
            } footer: {
                Text("文件落在 Documents/Pulled/<名字>/，日志在 Documents/cp-log.txt。")
            }

            Section {
                TextField("Bundle ID", text: $bundleID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.footnote, design: .monospaced))
                Button("按 bundle id 找容器并拉取") {
                    start { pullByBundleID() }
                }
            } header: {
                HeaderLabel("By Bundle ID", symbol: "magnifyingglass")
            } footer: {
                Text("枚举 Data/Application 下的容器、读 metadata 匹配 bundle id，然后整锅拉。300+ 个容器，要几十秒。")
            }

            Section {
                LabeledContent("Status", value: status)
                LabeledContent("Files", value: "\(fileCount)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
            } header: {
                HeaderLabel("Progress", symbol: "chart.bar")
            }

            Section {
                Button("清空 Documents/Pulled", role: .destructive) {
                    start { clearPulled() }
                }
            } footer: {
                Text("删掉已经拉取到 App 里的所有副本，不动设备上任何原文件。")
            }
        }
        .navigationTitle("Container Pull")
        .disabled(running)
    }

    // MARK: - 基础

    private func appendLog(_ line: String) {
        print("(cp) \(line)")
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// 先按 iOS 27 的默认 flags 试，失败再按 iOS 26 的 alt flags 试
    private func rawGrant(_ path: String) -> Int64 {
        var handle = worse_query(path, group, false, true)
        appendLog("grant(normal) \(path) -> \(handle)")
        if handle < 0 {
            handle = worse_query(path, group, true, true)
            appendLog("grant(alt)    \(path) -> \(handle)")
        }
        return handle
    }

    private func start(_ work: @escaping () -> Void) {
        guard !running else { return }
        running = true
        status = "Running…"
        fileCount = 0
        byteCount = 0
        appendLog("=== start \(Date()) ===")
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { running = false }
        }
    }

    private func note(_ text: String) {
        appendLog(text)
        DispatchQueue.main.async { status = text }
    }

    private func bump(_ size: Int64) {
        DispatchQueue.main.async {
            fileCount += 1
            byteCount += size
        }
    }

    // MARK: - 诊断

    private func writeProbe() {
        let paths = [
            appGroupRoot,
            notesGroup,
            container,
            container + "/Documents",
            "/private/var/mobile/Containers/Data/Application",
            "/var/mobile/Media/DCIM",
        ]
        var report = "\n--- probe \(Date()) ---\n"
        for path in paths {
            for alt in [false, true] {
                let h = worse_query(path, group, alt, true)
                report += "\(alt ? "alt   " : "normal")  \(h)\t\(path)\n"
                if h >= 0 { worse_query_release(h) }
            }
        }
        try? (report.data(using: .utf8) ?? Data())
            .write(to: URL.documentsDirectory.appendingPathComponent("probe.txt"))
        note("诊断写入 probe.txt")
    }

    // MARK: - 清理

    private func clearPulled() {
        do {
            try fm.removeItem(at: dest)
            note("已清空 Documents/Pulled")
        } catch {
            note("清空失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 拉取

    private func pullNotesGroup() {
        var target: String?

        // 先试已知路径（换设备/重装后 UUID 会变，所以后面还有扫描兜底）
        if rawGrant(notesGroup) >= 0 {
            target = notesGroup
        }

        if target == nil {
            guard rawGrant(appGroupRoot) >= 0 else {
                return note("AppGroup 拿不到 extension, 见 cp-log.txt")
            }
            if let dirs = try? fm.contentsOfDirectory(atPath: appGroupRoot) {
                for dir in dirs {
                    let path = appGroupRoot + "/" + dir
                    let handle = rawGrant(path)
                    guard handle >= 0 else { continue }
                    let meta = path + "/.com.apple.mobile_container_manager.metadata.plist"
                    if let dict = NSDictionary(contentsOfFile: meta),
                       let ident = dict["MCMMetadataIdentifier"] as? String,
                       ident == "group.com.apple.notes" {
                        target = path
                        worse_query_release(handle)
                        break
                    }
                    worse_query_release(handle)
                }
            }
        }

        guard let target else { return note("没找到 group.com.apple.notes") }
        DispatchQueue.main.async { container = target }
        note("目标: \(target)")

        // 关键: 路径显式传进去, 不读 @State
        pull(path: target, sub: "", as: "NotesGroup")
    }

    /// 枚举 Data/Application 下所有容器，按 metadata 里的 bundle id 匹配
    private func pullByBundleID() {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return note("bundle id 为空") }

        // bad_query_list 内部会把 fsgetpath 的 "/private/var/..." 剥成 "/var/..." 再和入参比较，
        // 所以这里必须传不带 /private 的形态，否则永远是 0 条。
        let root = "/var/mobile/Containers/Data/Application"
        let paths = fsHandlers.getDirPaths(root).filter { !$0.isEmpty }
        appendLog("枚举到 \(paths.count) 个容器，开始匹配 \(bid)")
        note("枚举到 \(paths.count) 个容器")
        guard !paths.isEmpty else {
            return note("枚举结果为空，检查 bad_query_list 的路径形态")
        }

        for raw in paths {
            let path = raw.hasPrefix("/var/") ? "/private" + raw : raw
            let handle = rawGrant(path)
            guard handle >= 0 else { continue }
            let meta = path + "/.com.apple.mobile_container_manager.metadata.plist"
            if let dict = NSDictionary(contentsOfFile: meta),
               let ident = dict["MCMMetadataIdentifier"] as? String,
               ident == bid {
                worse_query_release(handle)
                DispatchQueue.main.async { container = path }
                note("找到 \(bid): \(path)")
                pull(path: path, sub: "", as: bid)
                return
            }
            worse_query_release(handle)
        }
        note("没找到 \(bid)")
    }

    private func pull(path: String, sub: String, as name: String) {
        let root = sub.isEmpty ? path : path + "/" + sub
        let handle = rawGrant(root)
        guard handle >= 0 else {
            return note("grant 失败（\(handle)）: \(root)")
        }
        defer { worse_query_release(handle) }

        let outDir = dest.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return note("枚举失败: \(root)")
        }

        appendLog("enumerate \(root) -> \(outDir.path)")

        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }

            let rel = url.path.hasPrefix(root + "/")
                ? String(url.path.dropFirst(root.count + 1))
                : url.lastPathComponent
            let dst = outDir.appendingPathComponent(rel)

            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: url, to: dst)
                let size = (try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber
                bump(size?.int64Value ?? 0)
            } catch {
                appendLog("copy failed \(url.path): \(error.localizedDescription)")
            }
        }
        note("完成: \(name)")
    }
}
