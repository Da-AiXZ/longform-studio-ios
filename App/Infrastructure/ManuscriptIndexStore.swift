import Foundation
import NovelCore

actor ManuscriptIndexStore {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL) {
        self.rootURL = rootURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func live() -> ManuscriptIndexStore {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return ManuscriptIndexStore(rootURL: base.appendingPathComponent("LongformStudio/AnalysisIndexes", isDirectory: true))
    }

    func save(_ index: ManuscriptIndex) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = rootURL.appendingPathComponent("\(index.sourceHash).json")
        try encoder.encode(index).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    func load(sourceHash: String) throws -> ManuscriptIndex? {
        let url = rootURL.appendingPathComponent("\(sourceHash).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ManuscriptIndex.self, from: Data(contentsOf: url))
    }

    func contains(sourceHash: String) -> Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("\(sourceHash).json").path)
    }

    func delete(sourceHash: String) throws {
        let url = rootURL.appendingPathComponent("\(sourceHash).json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func validate() throws -> Int {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return 0 }
        let urls = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
        for url in urls { _ = try decoder.decode(ManuscriptIndex.self, from: Data(contentsOf: url)) }
        return urls.count
    }
}
