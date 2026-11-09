//
//  PhotoPullView.swift
//  Erosion
//
//  用 worse_query 把相册数据拉到 App 自己的 Documents 里,
//  再由电脑端 AFC 取走（不用分享面板、不用一张张点）。
//
//  关键点: worse_query 的默认入口会先 lstat 目标路径,
//  /var/mobile/Media 这类受保护路径连 metadata 都被 sandbox 挡,
//  于是直接 return -255。这里一律用 create_dir = true 调用,
//  跳过那道预检, 让 containermanagerd 去解析符号链接。
//

import SwiftUI

struct PhotoPullView: View {
    @EnvironmentObject private var mgr: ErosionManager

    @State private var running = false
    @State private var status = "Idle"
    @State private var fileCount = 0
    @State private var byteCount: Int64 = 0

    private let dcimRoot = "/var/mobile/Media/DCIM"
    private let photoDataRoot = "/var/mobile/Media/PhotoData"

    private var dest: URL {
        URL.documentsDirectory.appendingPathComponent("Pulled", isDirectory: true)
    }

    var body: some View {
        List {
            Section {
                Button("Photos.sqlite（相册数据库）") {
                    start { pullDatabase() }
                }
                Button("DCIM（全部照片/视频）") {
                    start { pullDCIM() }
                }
            } header: {
                HeaderLabel("Photo Library", symbol: "photo.on.rectangle.angled")
            } footer: {
                Text("走 worse_query（create_dir=true 跳过 lstat 预检），文件写进 App 的 Documents/Pulled，之后用电脑端 AFC 拉走。")
            }

            Section {
                LabeledContent("Status", value: status)
                LabeledContent("Files", value: "\(fileCount)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
            } header: {
                HeaderLabel("Progress", symbol: "chart.bar")
            }
        }
        .navigationTitle("Photo Pull")
        .disabled(running)
    }

    // MARK: - 底层

    /// create_dir = true: 跳过 worse_query 里的 lstat 预检（-255 就是它返回的）
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
        print("(pl) \(text)")
        DispatchQueue.main.async { status = text }
    }

    private func copyFile(_ srcPath: String, to name: String) {
        let dst = dest.appendingPathComponent(name)
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: URL(fileURLWithPath: srcPath), to: dst)
            let attrs = try? fm.attributesOfItem(atPath: dst.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            DispatchQueue.main.async {
                fileCount += 1
                byteCount += size
            }
        } catch {
            print("(pl) copy failed \(srcPath): \(error.localizedDescription)")
        }
    }

    // MARK: - 具体流程

    private func pullDatabase() {
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let handle = rawGrant(photoDataRoot)
        guard handle >= 0 else {
            return note("PhotoData grant 失败: \(handle)")
        }
        defer { worse_query_release(handle) }

        for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
            let src = photoDataRoot + "/" + name
            if fm.fileExists(atPath: src) { copyFile(src, to: name) }
        }
        note("数据库拉取完成")
    }

    private func pullDCIM() {
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let rootHandle = rawGrant(dcimRoot)
        guard rootHandle >= 0 else {
            return note("DCIM grant 失败: \(rootHandle)")
        }
        let subdirs = (try? fm.contentsOfDirectory(atPath: dcimRoot)) ?? []
        worse_query_release(rootHandle)

        guard !subdirs.isEmpty else {
            return note("DCIM 列不出来（extension 递归没覆盖？）")
        }
        print("(pl) DCIM 子目录: \(subdirs.sorted())")

        for dir in subdirs.sorted() where !dir.hasPrefix(".") {
            let sub = dcimRoot + "/" + dir
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue else { continue }

            let handle = rawGrant(sub)
            guard handle >= 0 else {
                print("(pl) grant failed \(sub): \(handle)")
                continue
            }
            let files = (try? fm.contentsOfDirectory(atPath: sub)) ?? []
            for file in files where !file.hasPrefix(".") {
                copyFile(sub + "/" + file, to: "\(dir)_\(file)")
            }
            worse_query_release(handle)
            note("已处理 \(dir)（\(files.count) 个）")
        }
        note("DCIM 拉取完成")
    }
}
