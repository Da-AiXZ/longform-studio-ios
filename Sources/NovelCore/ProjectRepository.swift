import Foundation

public enum ProjectRepositoryError: LocalizedError {
    case projectNotFound
    case unsupportedSchema(Int)
    case invalidArchive

    public var errorDescription: String? {
        switch self {
        case .projectNotFound: return "找不到作品工程。"
        case .unsupportedSchema(let version): return "工程版本 \(version) 暂不受支持。"
        case .invalidArchive: return "工程备份格式无效。"
        }
    }
}

public actor ProjectRepository {
    public static let currentSchemaVersion = 1

    private nonisolated let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func listProjects() throws -> [NovelProject] {
        try prepare()
        let directories = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return directories.compactMap { directory in
            try? decode(NovelProject.self, from: directory.appendingPathComponent("manifest.json"))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func createProject(_ project: NovelProject) throws -> ProjectWorkspace {
        var normalized = project
        normalized.schemaVersion = Self.currentSchemaVersion
        let workspace = ProjectWorkspace(project: normalized)
        try save(workspace)
        return workspace
    }

    public func loadProject(id: UUID) throws -> ProjectWorkspace {
        let directory = projectDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ProjectRepositoryError.projectNotFound }
        let project = try decode(NovelProject.self, from: directory.appendingPathComponent("manifest.json"))
        guard project.schemaVersion <= Self.currentSchemaVersion else { throw ProjectRepositoryError.unsupportedSchema(project.schemaVersion) }

        return ProjectWorkspace(
            project: project,
            bible: decodeIfPresent(StoryBible.self, from: directory.appendingPathComponent("bible.json")) ?? StoryBible(),
            characters: decodeIfPresent([Character].self, from: directory.appendingPathComponent("references/characters.json")) ?? [],
            worldRules: decodeIfPresent([WorldRule].self, from: directory.appendingPathComponent("references/world-rules.json")) ?? [],
            timeline: decodeIfPresent([TimelineEvent].self, from: directory.appendingPathComponent("references/timeline.json")) ?? [],
            foreshadowing: decodeIfPresent([Foreshadowing].self, from: directory.appendingPathComponent("references/foreshadowing.json")) ?? [],
            volumes: decodeIfPresent([VolumeOutline].self, from: directory.appendingPathComponent("planning/volumes.json")) ?? [],
            chapters: try decodeDirectory(ChapterCard.self, directory: directory.appendingPathComponent("chapters/cards")),
            versions: try loadVersionMetadata(directory: directory),
            facts: decodeIfPresent([ContinuityFact].self, from: directory.appendingPathComponent("continuity/facts.json")) ?? [],
            reviews: try decodeDirectory(ReviewReport.self, directory: directory.appendingPathComponent("reviews")),
            generationRecords: try decodeDirectory(GenerationRecord.self, directory: directory.appendingPathComponent("generations")),
            planningArtifacts: try decodeDirectory(PlanningArtifact.self, directory: directory.appendingPathComponent("planning/artifacts")),
            styleProfile: decodeIfPresent(StyleProfile.self, from: directory.appendingPathComponent("style-profile.json"))
        )
    }

    public func save(_ workspace: ProjectWorkspace) throws {
        try prepare()
        let directory = projectDirectory(workspace.project.id)
        try createProjectDirectories(directory)

        var project = workspace.project
        project.schemaVersion = Self.currentSchemaVersion
        project.updatedAt = Date()
        try encode(project, to: directory.appendingPathComponent("manifest.json"))
        try encode(workspace.bible, to: directory.appendingPathComponent("bible.json"))
        try encode(workspace.characters, to: directory.appendingPathComponent("references/characters.json"))
        try encode(workspace.worldRules, to: directory.appendingPathComponent("references/world-rules.json"))
        try encode(workspace.timeline, to: directory.appendingPathComponent("references/timeline.json"))
        try encode(workspace.foreshadowing, to: directory.appendingPathComponent("references/foreshadowing.json"))
        try encode(workspace.volumes, to: directory.appendingPathComponent("planning/volumes.json"))
        try encode(workspace.facts, to: directory.appendingPathComponent("continuity/facts.json"))
        if let styleProfile = workspace.styleProfile {
            try encode(styleProfile, to: directory.appendingPathComponent("style-profile.json"))
        }

        for chapter in workspace.chapters {
            try encode(chapter, to: directory.appendingPathComponent("chapters/cards/\(chapter.id.uuidString).json"))
        }
        for version in workspace.versions {
            let bodyURL = directory.appendingPathComponent("chapters/bodies/\(version.id.uuidString).txt")
            if version.isBodyLoaded || !FileManager.default.fileExists(atPath: bodyURL.path) {
                try Data(version.body.utf8).write(to: bodyURL, options: [.atomic])
            }
            var metadata = version
            if version.isBodyLoaded {
                metadata.characterCount = TextAnalyzer.statistics(for: version.body).chineseCharacterCount
            }
            metadata.body = ""
            metadata.isBodyLoaded = false
            try encode(metadata, to: directory.appendingPathComponent("chapters/versions/\(version.id.uuidString).json"))
        }
        for review in workspace.reviews {
            try encode(review, to: directory.appendingPathComponent("reviews/\(review.id.uuidString).json"))
        }
        for record in workspace.generationRecords {
            try encode(record, to: directory.appendingPathComponent("generations/\(record.id.uuidString).json"))
        }
        for artifact in workspace.planningArtifacts {
            try encode(artifact, to: directory.appendingPathComponent("planning/artifacts/\(artifact.id.uuidString).json"))
        }
    }

    public func exportArchive(_ workspace: ProjectWorkspace) throws -> Data {
        var hydrated = workspace
        for index in hydrated.versions.indices where !hydrated.versions[index].isBodyLoaded {
            hydrated.versions[index].body = try loadVersionBody(projectID: workspace.project.id, versionID: hydrated.versions[index].id)
            hydrated.versions[index].isBodyLoaded = true
        }
        return try encoder.encode(ProjectArchive(workspace: hydrated))
    }

    public func importArchive(_ data: Data) throws -> ProjectWorkspace {
        let archive: ProjectArchive
        do {
            archive = try decoder.decode(ProjectArchive.self, from: data)
        } catch {
            throw ProjectRepositoryError.invalidArchive
        }
        guard archive.archiveVersion == 1 else { throw ProjectRepositoryError.invalidArchive }
        var workspace = archive.workspace
        if FileManager.default.fileExists(atPath: projectDirectory(workspace.project.id).path) {
            workspace.project.id = UUID()
        }
        workspace.project.updatedAt = Date()
        try save(workspace)
        return workspace
    }

    public func importManuscript(title: String, text: String, platform: PublishingPlatform = .qidian) throws -> ProjectWorkspace {
        let project = NovelProject(title: title, platform: platform, genre: "待补充", sellingPoint: "", targetWordCount: max(100_000, text.count), protagonistGoal: "")
        var workspace = ProjectWorkspace(project: project)
        let sections = ManuscriptImporter.splitIntoChapters(text)
        for (offset, section) in sections.enumerated() {
            var chapter = ChapterCard(number: offset + 1, title: section.title, status: .drafting)
            let version = ChapterVersion(chapterID: chapter.id, source: .imported, body: section.body)
            chapter.activeVersionID = version.id
            chapter.versionIDs = [version.id]
            workspace.chapters.append(chapter)
            workspace.versions.append(version)
        }
        try save(workspace)
        return workspace
    }

    public func deleteProject(id: UUID) throws {
        let directory = projectDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func loadVersionBody(projectID: UUID, versionID: UUID) throws -> String {
        let directory = projectDirectory(projectID)
        let bodyURL = directory.appendingPathComponent("chapters/bodies/\(versionID.uuidString).txt")
        if FileManager.default.fileExists(atPath: bodyURL.path) {
            return try String(decoding: Data(contentsOf: bodyURL), as: UTF8.self)
        }
        let legacyURL = directory.appendingPathComponent("chapters/versions/\(versionID.uuidString).json")
        return try decode(ChapterVersion.self, from: legacyURL).body
    }

    public func searchPassages(projectID: UUID, versionIDs: [UUID], query: String, limit: Int = 12) throws -> [ContextItem] {
        var results: [ContextItem] = []
        for versionID in versionIDs {
            let body = try loadVersionBody(projectID: projectID, versionID: versionID)
            for (index, paragraph) in TextAnalyzer.normalizedParagraphs(body).enumerated() where paragraph.count >= 30 {
                let relevance = ContextBuilder.relevance(of: paragraph, to: query)
                if relevance > 0 {
                    results.append(ContextItem(id: "passage-\(versionID)-\(index)", category: .retrievedPassage, title: "历史相关段落", text: paragraph, priority: 25, relevance: relevance))
                }
            }
        }
        return Array(results.sorted { $0.relevance > $1.relevance }.prefix(limit))
    }

    public func exportManuscript(_ workspace: ProjectWorkspace, markdown: Bool, selectedChapterID: UUID? = nil, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chapters = workspace.chapters
            .filter { selectedChapterID == nil || $0.id == selectedChapterID }
            .sorted { $0.number < $1.number }
        for (index, chapter) in chapters.enumerated() {
            guard let versionID = chapter.activeVersionID,
                  let version = workspace.versions.first(where: { $0.id == versionID }) else { continue }
            let body = version.isBodyLoaded ? version.body : try loadVersionBody(projectID: workspace.project.id, versionID: versionID)
            let heading = markdown ? "# \(chapter.title)" : chapter.title
            let separator = index == 0 ? "" : "\n\n"
            try handle.write(contentsOf: Data("\(separator)\(heading)\n\n\(body)".utf8))
        }
    }

    public nonisolated func projectDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func createProjectDirectories(_ directory: URL) throws {
        let paths = [
            directory,
            directory.appendingPathComponent("references", isDirectory: true),
            directory.appendingPathComponent("planning", isDirectory: true),
            directory.appendingPathComponent("planning/artifacts", isDirectory: true),
            directory.appendingPathComponent("chapters/cards", isDirectory: true),
            directory.appendingPathComponent("chapters/versions", isDirectory: true),
            directory.appendingPathComponent("chapters/bodies", isDirectory: true),
            directory.appendingPathComponent("continuity", isDirectory: true),
            directory.appendingPathComponent("reviews", isDirectory: true),
            directory.appendingPathComponent("generations", isDirectory: true)
        ]
        for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func decodeIfPresent<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? decode(type, from: url)
    }

    private func decodeDirectory<T: Decodable>(_ type: T.Type, directory: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decode(type, from: $0) }
    }

    private func loadVersionMetadata(directory: URL) throws -> [ChapterVersion] {
        var versions = try decodeDirectory(ChapterVersion.self, directory: directory.appendingPathComponent("chapters/versions"))
        for index in versions.indices {
            let bodyURL = directory.appendingPathComponent("chapters/bodies/\(versions[index].id.uuidString).txt")
            if FileManager.default.fileExists(atPath: bodyURL.path) {
                versions[index].body = ""
                versions[index].isBodyLoaded = false
            }
        }
        return versions
    }
}

public enum ManuscriptImporter {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    public static func splitIntoChapters(_ text: String) -> [Section] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [Section] = []
        var title = "第1章 导入正文"
        var body: [String] = []

        func isHeading(_ line: String) -> Bool {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.count <= 40 else { return false }
            return (value.hasPrefix("第") && value.contains("章")) || value.hasPrefix("# ") || value.hasPrefix("## ")
        }

        for line in lines {
            if isHeading(line) {
                if !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append(Section(title: title, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                body = []
            } else {
                body.append(line)
            }
        }
        if !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(Section(title: title, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return sections.isEmpty ? [Section(title: title, body: text)] : sections
    }
}
