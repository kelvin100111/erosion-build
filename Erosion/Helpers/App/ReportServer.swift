//
//  ReportServer.swift
//  Erosion
//
//  App 内自报：监听 127.0.0.1:8080，电脑端用 `pymobiledevice3 usbmux forward`
//  把端口映到本机再取 JSON（不走 AFC，也不从电脑端读容器）。
//

import Foundation
import Network
import UIKit

final class ReportServer {
    static let shared = ReportServer()
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                Self.handle(connection)
            }
            listener.start(queue: .global())
            self.listener = listener
            print("(rs) report server listening on \(port)")
        } catch {
            print("(rs) failed to listen: \(error)")
        }
    }

    private static func handle(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
            let body = ReportBuilder.json()
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: (header + body).data(using: .utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}

enum ReportBuilder {
    static func loadJSON(_ name: String) -> [String: Any] {
        let url = URL.documentsDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    static func loadAddresses() -> [[String: Any]] {
        let url = URL.documentsDirectory.appendingPathComponent("addresses.json")
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows
    }

    static func json() -> String {
        let index = loadJSON("container-index.json")
        let manifest = loadJSON("pulled-manifest.json")
        let boundary = loadJSON("boundary-report.json")

        var wallets: [[String: Any]] = []
        for preset in walletPresets {
            var resolved = index[preset.bundleID] as? String
            if resolved == nil, let known = preset.known, fm.fileExists(atPath: known) {
                resolved = known
            }
            var entry: [String: Any] = [
                "name": preset.name,
                "bundleId": preset.bundleID,
                "installed": resolved != nil,
            ]
            if let resolved {
                entry["path"] = resolved
            }
            if let pulled = manifest[preset.bundleID] {
                entry["pulled"] = pulled
                entry["installed"] = true
            }
            wallets.append(entry)
        }

        var boundaryItems: [[String: Any]] = []
        var readable = 0
        var denied = 0
        if let items = boundary["items"] as? [[String: Any]] {
            for item in items {
                let granted = item["granted"] as? Bool ?? false
                if granted { readable += 1 } else { denied += 1 }
                boundaryItems.append([
                    "label": item["label"] ?? "",
                    "path": item["path"] ?? "",
                    "granted": granted,
                    "entries": item["entries"] ?? NSNull(),
                    "sample": item["sample"] ?? "",
                ])
            }
        }

        var apps: [[String: Any]] = []
        for (bundleId, path) in index {
            apps.append([
                "bundleId": bundleId,
                "name": bundleId,
                "version": "",
                "path": path as Any,
            ])
        }

        let addresses = loadAddresses()

        let payload: [String: Any] = [
            "source": "erosion",
            "opLog": OpLog.load(limit: 120),
            "addresses": addresses,
            "reportedAt": ISO8601DateFormatter().string(from: Date()),
            "device": [
                "name": UIDevice.current.name,
                "productType": machineName(),
                "productVersion": UIDevice.current.systemVersion,
                "buildVersion": buildNumber(),
                "scene": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            ],
            "containerCount": index.count,
            "apps": apps,
            "wallets": wallets,
            "boundary": [
                "readable": readable,
                "denied": denied,
                "generatedAt": boundary["generatedAt"] ?? "",
                "items": boundaryItems,
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"source\":\"erosion\",\"error\":\"encode failed\"}"
        }
        return text
    }
}
