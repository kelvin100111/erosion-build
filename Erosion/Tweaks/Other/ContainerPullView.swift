//
//  ContainerPullView.swift
//  Erosion
//
//  把任意 app 的数据容器 / App Group 容器复制进自己的 Documents,
//  再由电脑端 AFC 取走。
//
//  两条经验:
//  1. worse_query 的 kernel extension 只覆盖容器根目录, /var/mobile/Media 不在内 -> -6
//  2. App Group 容器在 iOS 26 需要 alt flags (0x0000000800000000);
//     iOS 27 未必一样, 所以这里两种 flags 都试一遍, 并把结果写进 Documents/cp-log.txt
//

import SwiftUI

struct ContainerPullView: View {
    @EnvironmentObject private var mgr: ErosionManager

    @State private var container = "/private/var/mobile/Containers/Data/Application/F443C7AE-3166-4EF3-B633-61D4BA9F4FF7"
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
                Text("默认是备忘录的 app 容器。App Group 容器要用下面的预设按钮。")
            }

            Section {
                Button("备忘录 App Group（group.com.apple.notes）") {
                    start { pullNotesGroup() }
                }
                Button("整个容器") {
                    start { pull(sub: "", as: "Container") }
                }
                Button("诊断：把各路径的返回码写进 cp-log.txt") {
                    start { writeProbe() }
                }
            } header: {
                HeaderLabel("Pull", symbol: "arrow.down.doc")
            } footer: {
                Text("文件落在 Documents/Pulled/<名字>/；诊断结果在 Documents/cp-log.txt。")
            }

            Section {
                LabeledContent("Status", value: status)
                LabeledContent("Files", value: "\(fileCount)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
            } header: {
                HeaderLabel("Progress", symbol: "chart.bar")
            }
        }
        .navigationTitle("Container Pull")
        .disabled(running)
    }

    // MARK: - 基础工具

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
        let data = report.data(using: .utf8) ?? Data()
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("probe.txt"))
        note("诊断写入 probe.txt")
    }

    // MARK: - 拉取

    private func pullNotesGroup() {
        var target: String?
        for candidate in [notesGroup, appGroupRoot] {
            let handle = rawGrant(candidate)
            if handle >= 0 {
                target = candidate
                worse_query_release(handle)
                break
            }
        }

        if target == nil {
            // 父目录拿到了, 再在里面找 group.com.apple.notes
            let handle = rawGrant(appGroupRoot)
            guard handle >= 0 else { return note("AppGroup 拿不到 extension, 见 cp-log.txt") }
            if let dirs = try? fm.contentsOfDirectory(atPath: appGroupRoot) {
                for dir in dirs {
                    let path = appGroupRoot + "/" + dir
                    let h = rawGrant(path)
                    guard h >= 0 else { continue }
                    let meta = path + "/.com.apple.mobile_container_manager.metadata.plist"
                    if let dict = NSDictionary(contentsOfFile: meta),
                       let ident = dict["MCMMetadataIdentifier"] as? String,
                       ident == "group.com.apple.notes" {
                        target = path
                        worse_query_release(h)
                        break
                    }
                    worse_query_release(h)
                }
            }
            worse_query_release(handle)
        }

        guard let target else { return note("没找到 group.com.apple.notes") }
        DispatchQueue.main.async { container = target }
        note("目标: \(target)")
        pull(sub: "", as: "NotesGroup")
    }

    private func pull(sub: String, as name: String) {
        let root = sub.isEmpty ? container : container + "/" + sub
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

            let rel = url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : url.lastPathComponent
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
        note("完成: \(name)（\(fileCount) 个文件）")
    }
}
