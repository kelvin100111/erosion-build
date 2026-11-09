//
//  BoundaryProbeView.swift
//  Erosion
//
//  权限边界探测：用 worse_query 逐条尝试路径，把返回码 / 能否列目录 / 样本
//  直接显示在 App 里（不依赖电脑端 AFC）。
//

import SwiftUI

struct ProbeTarget: Identifiable {
    var id: String { path }
    let path: String
    let label: String
}

struct ProbeResult: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    var normal: Int64 = -999
    var alt: Int64 = -999
    var retry: Int64 = -999
    var isDirectory = false
    var entries: Int? = nil
    var sample: String = ""
    var size: Int64? = nil

    var best: Int64 { max(normal, max(alt, retry)) }
    var granted: Bool { best >= 0 }
}

private let probeTargets: [ProbeTarget] = [
    .init(path: "/var/mobile/Containers/Data/Application", label: "Data 容器父目录"),
    .init(path: "/private/var/mobile/Containers/Data/Application/724F56B3-8E24-4CE8-9E6B-61DD9CFB24CD", label: "MetaMask 容器"),
    .init(path: "/private/var/mobile/Containers/Data/Application/724F56B3-8E24-4CE8-9E6B-61DD9CFB24CD/Documents", label: "MetaMask /Documents"),
    .init(path: "/private/var/mobile/Containers/Data/Application/E39CC27E-CCA1-4AE5-9775-319D22BA451E", label: "微信 容器"),
    // ---- 已装钱包：逐个确认容器能不能授权、能列多少 ----
    .init(path: "/private/var/mobile/Containers/Data/Application/3B02DE05-A091-4897-8DDB-A4BA0411E5AC", label: "钱包 · Trust Wallet"),
    .init(path: "/private/var/mobile/Containers/Data/Application/49128A09-3A1B-4684-95E6-493D5127F427", label: "钱包 · imToken"),
    .init(path: "/private/var/mobile/Containers/Data/Application/C3168EA3-48FD-44E6-AED5-6E2D6A7B5BDA", label: "钱包 · TokenPocket"),
    .init(path: "/private/var/mobile/Containers/Data/Application/27FE096B-5259-4A53-AA15-F6D675DD99EE", label: "钱包 · Bitget Wallet"),
    .init(path: "/private/var/mobile/Containers/Data/Application/7D0041F1-BFDF-4D2C-AEC3-6DA8E69B2DEB", label: "钱包 · Bybit"),
    .init(path: "/private/var/mobile/Containers/Data/Application/5967BFCC-54C8-402F-B190-BF1A8C2A2AAE", label: "钱包 · MathWallet"),
    .init(path: "/private/var/mobile/Containers/Data/Application/4EF89310-5A08-485D-849F-CCE4F61528ED", label: "钱包 · 比特派 Bitpie"),
    .init(path: "/private/var/mobile/Containers/Data/Application/CC418DA1-1912-489D-9B2F-B2BF76E69086", label: "钱包 · TronLink"),
    .init(path: "/private/var/mobile/Containers/Data/Application/386206E7-6771-42AF-A1D2-A41141F006C6", label: "钱包 · CoolWallet"),
    .init(path: "/private/var/mobile/Containers/Data/Application/A82BA947-47B0-45E2-9C92-A00F8F8B79DC", label: "钱包 · Onchain"),
    .init(path: "/var/mobile/Containers/Shared/AppGroup", label: "AppGroup 父目录"),
    .init(path: "/var/mobile/Containers/Data/PluginKitPlugin", label: "PluginKit 容器"),
    .init(path: "/var/mobile/Containers/Data/InternalDaemon", label: "Daemon 容器"),
    .init(path: "/var/containers/Data/System", label: "System 容器"),
    .init(path: "/var/containers/Shared/SystemGroup", label: "SystemGroup 容器"),
    .init(path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist", label: "MobileGestalt 缓存"),
    .init(path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles", label: "配置描述文件目录"),
    .init(path: "/var/mobile/Media/DCIM", label: "相册 DCIM"),
    .init(path: "/var/mobile/Media/PhotoData/Photos.sqlite", label: "Photos.sqlite"),
    .init(path: "/var/mobile/Library/SMS/sms.db", label: "短信 sms.db"),
    .init(path: "/var/mobile/Library/AddressBook", label: "通讯录"),
    .init(path: "/var/mobile/Library/Safari/History.db", label: "Safari 历史"),
    .init(path: "/var/mobile/Library/Preferences", label: "系统偏好目录"),
    .init(path: "/var/Keychains", label: "Keychains（应被拒）"),
    .init(path: "/var/db", label: "系统数据库 /var/db"),
    .init(path: "/private/etc/hosts", label: "/etc/hosts"),
    .init(path: "/System/Library/CoreServices/SystemVersion.plist", label: "SSV 系统文件"),
]

struct BoundaryProbeView: View {
    @State private var results: [ProbeResult] = []
    @State private var running = false
    @State private var finished = 0
    @State private var writeTest = false
    @State private var startedAt = Date()

    private var grantedCount: Int { results.filter { $0.granted }.count }
    private var deniedCount: Int { results.filter { !$0.granted }.count }

    var body: some View {
        List {
            Section {
                Button {
                    run()
                } label: {
                    HStack {
                        Label("开始探测", systemImage: "scope")
                        Spacer()
                        if running {
                            ProgressView()
                        } else if !results.isEmpty {
                            Text("\(finished)/\(probeTargets.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(running)

                Toggle("写入测试（仅对已授权目录，写 4 字节再删）", isOn: $writeTest)
                    .font(.footnote)
            } header: {
                HeaderLabel("Probe", symbol: "scope")
            } footer: {
                Text("全部在 App 内完成：worse_query 申请 sandbox extension -> 列目录 / 读样本。绿色 = 拿到权限且能读，黄色 = 拿到权限但读不动，红色 = 被拒。")
            }

            if !results.isEmpty {
                Section {
                    HStack {
                        Label("可读 \(grantedCount)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Label("拒绝 \(deniedCount)", systemImage: "xmark.seal.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.subheadline)
                } header: {
                    HeaderLabel("Summary", symbol: "chart.pie")
                }

                Section {
                    ForEach(results) { result in
                        row(result)
                    }
                } header: {
                    HeaderLabel("结果", symbol: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("Boundary Probe")
        .disabled(running)
        .onAppear {
            if results.isEmpty { results = probeTargets.map { ProbeResult(label: $0.label, path: $0.path) } }
        }
    }

    // MARK: - UI

    @ViewBuilder
    private func row(_ result: ProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: result.granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.granted ? .green : .red)
                Text(result.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(codeText(result))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(result.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if result.granted {
                HStack(spacing: 8) {
                    if let entries = result.entries {
                        Text("\(entries) 项")
                            .font(.caption2)
                    }
                    if let size = result.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption2)
                    }
                    if !result.sample.isEmpty {
                        Text(result.sample)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func codeText(_ result: ProbeResult) -> String {
        "n:\(result.normal) a:\(result.alt) c:\(result.retry)"
    }

    // MARK: - 探测

    private func run() {
        running = true
        finished = 0
        startedAt = Date()
        results = probeTargets.map { ProbeResult(label: $0.label, path: $0.path) }

        DispatchQueue.global(qos: .userInitiated).async {
            var collected: [ProbeResult] = []

            for target in probeTargets {
                var result = ProbeResult(label: target.label, path: target.path)
                print("(bp) --- \(target.path)")

                result.normal = worse_query(target.path, group, false, false)
                result.alt = worse_query(target.path, group, true, false)
                result.retry = worse_query(target.path, group, false, true)
                print("(bp) normal \(result.normal) alt \(result.alt) retry \(result.retry)")

                var handle = result.best
                if handle < 0 {
                    handle = worse_query(target.path, group, true, true)
                    if handle > result.retry { result.retry = handle }
                    print("(bp) alt+create_dir \(handle)")
                }

                if handle >= 0 {
                    inspect(path: target.path, result: &result, writeTest: writeTest)
                    worse_query_release(handle)
                }

                collected.append(result)
                DispatchQueue.main.async {
                    finished = collected.count
                    if let index = results.firstIndex(where: { $0.path == result.path }) {
                        results[index] = result
                    }
                }
            }

            writeReport(collected)
            DispatchQueue.main.async {
                running = false
                finished = collected.count
            }
        }
    }

    private func inspect(path: String, result: inout ProbeResult, writeTest: Bool) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            result.sample = "不存在"
            return
        }
        result.isDirectory = isDir.boolValue

        if isDir.boolValue {
            let items = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            result.entries = items.count
            result.sample = items.prefix(3).joined(separator: ", ")

            if writeTest {
                let probeFile = (path as NSString).appendingPathComponent(".erosion-write-test")
                let ok = fm.createFile(atPath: probeFile, contents: Data([0x45, 0x52, 0x4F, 0x53]))
                try? fm.removeItem(atPath: probeFile)
                result.sample += ok ? "  [写入 OK]" : "  [写入 被拒]"
            }
        } else {
            let attrs = try? fm.attributesOfItem(atPath: path)
            result.size = (attrs?[.size] as? NSNumber)?.int64Value
            if let fh = FileHandle(forReadingAtPath: path) {
                let data = fh.readData(ofLength: 8)
                try? fh.close()
                result.sample = data.isEmpty ? "读不到内容" : "头 8 字节: " + data.map { String(format: "%02x", $0) }.joined()
            } else {
                result.sample = "打不开文件"
            }
        }
    }

    private func writeReport(_ collected: [ProbeResult]) {
        let rows: [[String: Any]] = collected.map { result in
            [
                "label": result.label,
                "path": result.path,
                "normal": result.normal,
                "alt": result.alt,
                "retry": result.retry,
                "granted": result.granted,
                "entries": result.entries as Any,
                "size": result.size as Any,
                "sample": result.sample,
            ]
        }
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "group": group,
            "device": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) \(machineName())",
            "items": rows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("boundary-report.json"))
        }
    }
}
