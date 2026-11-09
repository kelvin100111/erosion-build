//
//  ContainerPullView.swift
//  Erosion
//
//  把任意 app 的数据容器（或它下面的子目录）复制进自己的 Documents,
//  再由电脑端 AFC 取走。
//
//  为什么这个能行而相册不行:
//  worse_query 的 kernel extension 只覆盖容器根目录
//  (/var/mobile/Containers/Data/Application/* 等, 见上游 README),
//  /var/mobile/Media 不在里面, 所以打相册必然 -6。
//
//  默认目标: 备忘录 com.apple.mobilenotes 的容器 (NoteStore.sqlite 在里面)
//

import SwiftUI

struct ContainerPullView: View {
    @EnvironmentObject private var mgr: ErosionManager

    @State private var container = "/private/var/mobile/Containers/Data/Application/F443C7AE-3166-4EF3-B633-61D4BA9F4FF7"
    @State private var running = false
    @State private var status = "Idle"
    @State private var fileCount = 0
    @State private var byteCount: Int64 = 0

    private var dest: URL {
        URL.documentsDirectory.appendingPathComponent("Pulled", isDirectory: true)
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
                Text("默认是备忘录的容器。换别的 app 就填它的 UUID 路径（File Browser → Data Containers 里能看到）。")
            }

            Section {
                Button("备忘录数据库（Library/NoteStore）") {
                    start { pull(sub: "Library/NoteStore", as: "NoteStore") }
                }
                Button("备忘录 App Group（group.com.apple.notes）") {
                    start { pullNotesGroup() }
                }
                Button("整个容器") {
                    start { pull(sub: "", as: "Container") }
                }
            } header: {
                HeaderLabel("Pull", symbol: "arrow.down.doc")
            } footer: {
                Text("文件落在 App 的 Documents/Pulled/<名字>/，之后用电脑端 AFC 拉走。")
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

    // MARK: - 底层

    /// create_dir = true: 跳过 worse_query 里的 lstat 预检（/var/mobile/* 的 metadata 常被 sandbox 挡）
    private func rawGrant(_ path: String) -> Int64 {
        let needsAltFlags = path.contains("/var/mobile/Containers/Shared/AppGroup")
            && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
        return worse_query(path, group, needsAltFlags, true)
    }

    private func start(_ work: @escaping () -> Void) {
        guard !running else { return }
        running = true
        status = "Running…"
        fileCount = 0
        byteCount = 0
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { running = false }
        }
    }

    private func note(_ text: String) {
        print("(cp) \(text)")
        DispatchQueue.main.async { status = text }
    }

    private func bump(_ size: Int64) {
        DispatchQueue.main.async {
            fileCount += 1
            byteCount += size
        }
    }

    /// 在 /var/mobile/Containers/Shared/AppGroup 里按 metadata 找到 group.com.apple.notes
    private func pullNotesGroup() {
        let base = "/var/mobile/Containers/Shared/AppGroup"
        let baseHandle = rawGrant(base)
        guard baseHandle >= 0 else { return note("AppGroup grant 失败（\(baseHandle)）") }
        let dirs = (try? fm.contentsOfDirectory(atPath: base)) ?? []
        worse_query_release(baseHandle)

        guard !dirs.isEmpty else { return note("AppGroup 列不出来") }
        print("(cp) AppGroup 有 \(dirs.count) 个容器")

        var target: String?
        for dir in dirs {
            let path = base + "/" + dir
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

        guard let target else { return note("没找到 group.com.apple.notes") }
        DispatchQueue.main.async { container = target }
        note("找到: \(target)")
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
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return note("枚举失败: \(root)")
        }

        print("(cp) root=\(root) -> \(outDir.path)")

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
                print("(cp) copy failed \(url.path): \(error.localizedDescription)")
            }
        }
        note("完成: \(name)（\(fileCount) 个文件）")
    }
}
