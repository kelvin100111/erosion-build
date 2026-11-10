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
//  4. 钱包这种"一批 app 各拉一次"的场景, 扫一遍 inode 建索引就够了,
//     之后所有按钮都走 index, 不再重复 40M 次 fsgetpath
//

import SwiftUI

// MARK: - 钱包预设

struct WalletPreset: Identifiable, Hashable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    /// 本机已装钱包的容器路径 (来自 apps query)。换机/重装后 UUID 会变，
    /// 所以拉之前会用 xattr 校验，不匹配自动回落到扫描。
    var known: String? = nil

    var installedOnThisDevice: Bool { known != nil }
}

private func containerPath(_ uuid: String) -> String {
    "/private/var/mobile/Containers/Data/Application/\(uuid)"
}

/// 常用钱包预设。bundle id 全部对过 App Store（lookup by bundleId），
/// 本机已装的 11 个带了容器 UUID，点一下直接拉，不用等扫描。
let walletPresets: [WalletPreset] = [
    // ---- 本机已装 ----
    WalletPreset(name: "MetaMask", bundleID: "io.metamask.MetaMask",
                 known: containerPath("724F56B3-8E24-4CE8-9E6B-61DD9CFB24CD")),
    WalletPreset(name: "Trust Wallet", bundleID: "com.sixdays.trust",
                 known: containerPath("3B02DE05-A091-4897-8DDB-A4BA0411E5AC")),
    WalletPreset(name: "imToken", bundleID: "im.token.app",
                 known: containerPath("49128A09-3A1B-4684-95E6-493D5127F427")),
    WalletPreset(name: "TokenPocket", bundleID: "com.global.wallet.ios",
                 known: containerPath("C3168EA3-48FD-44E6-AED5-6E2D6A7B5BDA")),
    WalletPreset(name: "Bitget Wallet", bundleID: "com.bitkeep.os",
                 known: containerPath("27FE096B-5259-4A53-AA15-F6D675DD99EE")),
    WalletPreset(name: "Bybit", bundleID: "com.bybit.app",
                 known: containerPath("7D0041F1-BFDF-4D2C-AEC3-6DA8E69B2DEB")),
    WalletPreset(name: "MathWallet", bundleID: "com.mathglobal.mathwallet5",
                 known: containerPath("5967BFCC-54C8-402F-B190-BF1A8C2A2AAE")),
    WalletPreset(name: "比特派 Bitpie", bundleID: "com.bitpie.wallet",
                 known: containerPath("4EF89310-5A08-485D-849F-CCE4F61528ED")),
    WalletPreset(name: "TronLink", bundleID: "com.tronlink.hdwallet",
                 known: containerPath("CC418DA1-1912-489D-9B2F-B2BF76E69086")),
    WalletPreset(name: "CoolWallet", bundleID: "com.coolbitx.coolwallets",
                 known: containerPath("386206E7-6771-42AF-A1D2-A41141F006C6")),
    WalletPreset(name: "Onchain", bundleID: "com.defi.wallet",
                 known: containerPath("A82BA947-47B0-45E2-9C92-A00F8F8B79DC")),

    // ---- 常用但本机未装（装了就有容器，扫描可命中）----
    WalletPreset(name: "OKX Wallet", bundleID: "com.okx.wallet"),
    WalletPreset(name: "Coinbase Wallet", bundleID: "org.toshi.distribution"),
    WalletPreset(name: "Phantom", bundleID: "app.phantom"),
    WalletPreset(name: "Rabby", bundleID: "com.debank.rabby-mobile"),
    WalletPreset(name: "Rainbow", bundleID: "me.rainbow"),
    WalletPreset(name: "Uniswap Wallet", bundleID: "com.uniswap.mobile"),
    WalletPreset(name: "Crypto.com", bundleID: "co.mona.Monaco"),
    WalletPreset(name: "Ledger Live", bundleID: "com.ledger.live"),
    WalletPreset(name: "Trezor Suite", bundleID: "io.trezor.suite"),
    WalletPreset(name: "OneKey", bundleID: "so.onekey.wallet"),
    WalletPreset(name: "SafePal", bundleID: "walletapp.safepal.io"),
    WalletPreset(name: "Exodus", bundleID: "exodus-movement.exodus"),
    WalletPreset(name: "Blockchain.com", bundleID: "com.rainydayapps.Blockchain"),
    WalletPreset(name: "Zerion", bundleID: "com.dpfbop.zerion"),
    WalletPreset(name: "FoxWallet", bundleID: "com.foxwallet.app"),
    WalletPreset(name: "Keplr", bundleID: "com.chainapsis.keplrwallet"),
    WalletPreset(name: "Solflare", bundleID: "com.solflare.mobile"),
    WalletPreset(name: "Backpack", bundleID: "app.backpack.mobile"),
    WalletPreset(name: "Coin98", bundleID: "coin98.crypto.finance.insights"),
]

struct ContainerPullView: View {
    @EnvironmentObject private var mgr: ErosionManager

    @State private var container = "/private/var/mobile/Containers/Data/Application/F443C7AE-3166-4EF3-B633-61D4BA9F4FF7"
    @State private var bundleID = "com.tencent.xin"
    @State private var running = false
    @State private var status = "Idle"
    @State private var fileCount = 0
    @State private var byteCount: Int64 = 0

    /// bundle id -> 容器路径，扫一次缓存在 Documents/container-index.json
    @State private var index: [String: String] = [:]

    /// 启动自动拉取模式：off / missing / all
    @AppStorage("autoPullMode") private var autoPullMode = "missing"
    @State private var lastAutoPull: String?

    private let notesGroup = "/private/var/mobile/Containers/Shared/AppGroup/5FEEE48A-F19D-48C9-B524-9E40BB0875F1"
    private let appGroupRoot = "/private/var/mobile/Containers/Shared/AppGroup"

    private var dest: URL {
        URL.documentsDirectory.appendingPathComponent("Pulled", isDirectory: true)
    }
    private var logURL: URL {
        URL.documentsDirectory.appendingPathComponent("cp-log.txt")
    }
    private var indexURL: URL {
        URL.documentsDirectory.appendingPathComponent("container-index.json")
    }
    /// 每个钱包拉完之后写一条：文件数 / 字节数 / 顶层目录分布
    private var manifestURL: URL {
        URL.documentsDirectory.appendingPathComponent("pulled-manifest.json")
    }

    private var installedWallets: [WalletPreset] {
        walletPresets.filter { $0.installedOnThisDevice }
    }
    private var otherWallets: [WalletPreset] {
        walletPresets.filter { !$0.installedOnThisDevice }
    }

    var body: some View {
        List {
            // MARK: 启动自动拉
            Section {
                Picker("启动自动拉取", selection: $autoPullMode) {
                    Text("关闭").tag("off")
                    Text("只补缺").tag("missing")
                    Text("每次全量").tag("all")
                }
                .pickerStyle(.segmented)
                Button {
                    UserDefaults.standard.removeObject(forKey: "autoPullLastRun")
                    AutoPullService.shared.startIfDue()
                } label: {
                    Label("立刻自动拉一次（备忘录 + 钱包）", systemImage: "bolt.badge.clock")
                }
                if let last = lastAutoPull {
                    Text(last)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } header: {
                HeaderLabel("Auto", symbol: "clock.arrow.circlepath")
            } footer: {
                Text("打开 App 后自动把备忘录（App 容器 + AppGroup）和本机已装钱包拉到 Documents/Pulled；「只补缺」会跳过已经拉过的。")
            }

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

            // MARK: 钱包
            Section {
                Button {
                    start {
                        note("开始扫描容器索引…")
                        _ = scanContainers()
                    }
                } label: {
                    HStack {
                        Label("建立容器索引（扫一次，之后秒开）", systemImage: "square.stack.3d.up")
                        Spacer()
                        if !index.isEmpty {
                            Text("\(index.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    start { pullAllInstalledWallets() }
                } label: {
                    Label("拉取本机全部已装钱包（\(installedWallets.count)）", systemImage: "tray.and.arrow.down")
                }
            } header: {
                HeaderLabel("Wallets", symbol: "creditcard")
            } footer: {
                Text("每个钱包单独拉一份到 Documents/Pulled/<bundle id>/。索引建好后所有按钮都走缓存，不再重复扫 inode；已装钱包带本机容器 UUID，点一下直接拉。")
            }

            Section {
                ForEach(installedWallets) { wallet in
                    walletRow(wallet)
                }
            } header: {
                HeaderLabel("已安装", symbol: "checkmark.seal")
            }

            Section {
                ForEach(otherWallets) { wallet in
                    walletRow(wallet)
                }
            } header: {
                HeaderLabel("更多钱包（未装则扫不到容器）", symbol: "questionmark.circle")
            }

            Section {
                Button("微信（com.tencent.xin）") {
                    start {
                        let p = "/private/var/mobile/Containers/Data/Application/E39CC27E-CCA1-4AE5-9775-319D22BA451E"
                        DispatchQueue.main.async { container = p }
                        pull(path: p, sub: "", as: "com.tencent.xin")
                    }
                }
                TextField("Bundle ID", text: $bundleID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.footnote, design: .monospaced))
                Button("按 bundle id 扫描（inode 4000 万）") {
                    start { pullByBundleID() }
                }
            } header: {
                HeaderLabel("By Bundle ID", symbol: "magnifyingglass")
            } footer: {
                Text("预设按钮用的 UUID 是从电脑端 apps query 读到的实际容器路径，最稳；扫描是兜底，40M inode 只能扫到一部分容器。")
            }

            Section {
                LabeledContent("Status", value: status)
                LabeledContent("Files", value: "\(fileCount)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                LabeledContent("Indexed", value: "\(index.count)")
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
        .onAppear {
            loadIndex()
            refreshAutoPullState()
        }
    }

    private func refreshAutoPullState() {
        let url = URL.documentsDirectory.appendingPathComponent("auto-pull.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let finished = dict["finishedAt"] as? String else {
            lastAutoPull = nil
            return
        }
        let entries = (dict["entries"] as? [[String: Any]])?.count ?? 0
        let elapsed = dict["elapsed"] as? Int ?? 0
        lastAutoPull = "上次自动拉取：\(finished) · \(entries) 个目标 · \(elapsed)s"
    }

    // MARK: - 钱包

    @ViewBuilder
    private func walletRow(_ wallet: WalletPreset) -> some View {
        Button {
            start { pullWallet(wallet) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wallet.name)
                        .foregroundStyle(.primary)
                    Text(wallet.bundleID)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if index[wallet.bundleID] != nil {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func pullWallet(_ wallet: WalletPreset) {
        if let cached = index[wallet.bundleID] {
            note("索引命中 \(wallet.name)")
            pull(path: cached, sub: "", as: wallet.bundleID)
            return
        }

        if let known = wallet.known, rawGrant(known) >= 0 {
            if bundleID(at: known) == wallet.bundleID {
                remember(wallet.bundleID, known)
                note("本机路径命中 \(wallet.name)")
                pull(path: known, sub: "", as: wallet.bundleID)
                return
            }
        }

        note("索引里没有 \(wallet.name)，开始扫描")
        let found = scanContainers()
        if let path = found[wallet.bundleID] {
            pull(path: path, sub: "", as: wallet.bundleID)
        } else {
            note("没找到 \(wallet.name) 的容器（可能没装）")
        }
    }

    private func pullAllInstalledWallets() {
        var idx = index
        if idx.isEmpty { idx = scanContainers() }

        let targets = installedWallets.compactMap { wallet -> (String, String)? in
            if let path = idx[wallet.bundleID] { return (wallet.bundleID, path) }
            if let known = wallet.known {
                // 没授权前 fm.fileExists 一定是 false（沙箱连 stat 都不给），直接交给 grant 判定
                return (wallet.bundleID, known)
            }
            return nil
        }
        guard !targets.isEmpty else {
            return note("索引里没有已装钱包，先建索引")
        }

        note("批量拉取 \(targets.count) 个钱包")
        for (bid, path) in targets {
            pull(path: path, sub: "", as: bid)
        }
        note("批量完成：\(targets.count) 个钱包")
    }

    // MARK: - 索引

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !dict.isEmpty else { return }
        index = dict
        appendLog("载入索引 \(dict.count) 条")
    }

    private func saveIndex() {
        let data = (try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: indexURL)
    }

    private func remember(_ bid: String, _ path: String) {
        DispatchQueue.main.async {
            index[bid] = path
            saveIndex()
        }
    }

    /// 扫一遍 Data/Application，把 bundle id -> container 全存下来
    @discardableResult
    private func scanContainers() -> [String: String] {
        let root = "/var/mobile/Containers/Data/Application"
        let paths = fsHandlers.getDirPaths(root, maxInode: 40_000_000).filter { !$0.isEmpty }
        appendLog("扫描到 \(paths.count) 个容器目录")
        note("扫描到 \(paths.count) 个容器")

        var found: [String: String] = [:]
        for raw in paths {
            let path = raw.hasPrefix("/var/") ? "/private" + raw : raw
            let handle = rawGrant(path)
            guard handle >= 0 else { continue }
            if let ident = bundleID(at: path) {
                found[ident] = path
            }
            worse_query_release(handle)
        }

        DispatchQueue.main.async {
            index = found
            saveIndex()
        }
        note("索引完成：\(found.count) 个容器")
        return found
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
        var handle = worse_query(path, group, false, false)
        appendLog("grant(normal) \(path) -> \(handle)")
        if handle < 0 {
            handle = worse_query(path, group, true, false)
            appendLog("grant(alt)    \(path) -> \(handle)")
        }
        if handle < 0 {
            handle = worse_query(path, group, false, true)
            appendLog("grant(create) \(path) -> \(handle)")
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

    /// 先查索引；没有就扫一遍
    private func pullByBundleID() {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return note("bundle id 为空") }

        if let cached = index[bid] {
            note("索引命中 \(bid)")
            return pull(path: cached, sub: "", as: bid)
        }

        let found = scanContainers()
        guard let path = found[bid] else {
            return note("没找到 \(bid)")
        }
        pull(path: path, sub: "", as: bid)
    }

    /// 记录一次拉取结果，供电脑端 / 后台读取
    private func writeManifestEntry(bundleID: String, files: Int, bytes: Int64, fileList: [[String: Any]] = [], top: [[String: Any]]) {
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
        appendLog("manifest \(bundleID): \(files) files, \(bytes) bytes")
    }

    /// 容器的 bundle id 存在 xattr 里，比 metadata.plist 靠谱
    private func bundleID(at path: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 512)
        let len = buf.withUnsafeMutableBytes { ptr -> Int in
            getxattr(path, "com.apple.containermanager.identifier", ptr.baseAddress, 511, 0, XATTR_NOFOLLOW)
        }
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    private func pull(path: String, sub: String, as name: String) {
        let root = sub.isEmpty ? path : path + "/" + sub
        OpLog.append("pull", "start", "\(name) 请求容器权限")
        let handle = rawGrant(root)
        guard handle >= 0 else {
            OpLog.append("pull", "fail", "\(name) grant 失败 \(handle): \(root)")
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
            OpLog.append("pull", "fail", "\(name) 枚举失败: \(root)")
            return note("枚举失败: \(root)")
        }

        appendLog("enumerate \(root) -> \(outDir.path)")

        var copiedFiles = 0
        var copiedBytes: Int64 = 0
        var topStats: [String: (files: Int, bytes: Int64)] = [:]
        var fileList: [[String: Any]] = []

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
                let bytes = size?.int64Value ?? 0
                bump(bytes)

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
                appendLog("copy failed \(url.path): \(error.localizedDescription)")
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
        OpLog.append("pull", "done", "\(name)：\(copiedFiles) 个文件 / \(ByteCountFormatter.string(fromByteCount: copiedBytes, countStyle: .file))")
        note("完成: \(name)（\(copiedFiles) 个文件 / \(ByteCountFormatter.string(fromByteCount: copiedBytes, countStyle: .file))）")
    }
}
