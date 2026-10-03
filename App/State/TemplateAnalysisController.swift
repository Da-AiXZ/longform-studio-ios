import Foundation
import Combine
import NovelCore

private actor ManuscriptAnalysisWorker {
    struct Result: Sendable {
        var index: ManuscriptIndex
        var template: WritingTemplate
    }

    private let analyzer: StreamingManuscriptAnalyzer
    private let indexStore: ManuscriptIndexStore

    init(analyzer: StreamingManuscriptAnalyzer, indexStore: ManuscriptIndexStore) {
        self.analyzer = analyzer
        self.indexStore = indexStore
    }

    func run(
        sourceURL: URL,
        perspective: NarrativePerspective,
        progress: @escaping @Sendable (ManuscriptAnalysisProgress) -> Void
    ) async throws -> Result {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LongformStudio-Analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("source.\(sourceURL.pathExtension.isEmpty ? "txt" : sourceURL.pathExtension)")
        FileManager.default.createFile(atPath: copy.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: sourceURL)
        let writer = try FileHandle(forWritingTo: copy)
        do {
            while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            try reader.close()
            try writer.close()
        } catch {
            try? reader.close()
            try? writer.close()
            throw error
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: copy.path)
        try Task.checkCancellation()
        let index = try await analyzer.analyze(url: copy, progress: progress)
        try Task.checkCancellation()
        try await indexStore.save(index)
        return Result(index: index, template: analyzer.makeLocalTemplate(from: index, perspective: perspective))
    }
}

@MainActor
final class TemplateAnalysisController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case copying
        case scanning
        case ready
        case synthesizing
        case completed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = ManuscriptAnalysisProgress(processedBytes: 0, totalBytes: 0, chaptersFound: 0)
    @Published private(set) var index: ManuscriptIndex?
    @Published private(set) var template: WritingTemplate?

    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private let worker: ManuscriptAnalysisWorker
    private let indexStore: ManuscriptIndexStore

    init(analyzer: StreamingManuscriptAnalyzer = StreamingManuscriptAnalyzer(), indexStore: ManuscriptIndexStore = .live()) {
        self.indexStore = indexStore
        worker = ManuscriptAnalysisWorker(analyzer: analyzer, indexStore: indexStore)
    }

    func analyze(url: URL, perspective: NarrativePerspective = .thirdPersonLimited) {
        cancel()
        let currentOperationID = UUID()
        operationID = currentOperationID
        phase = .copying
        progress = ManuscriptAnalysisProgress(processedBytes: 0, totalBytes: 0, chaptersFound: 0)
        index = nil
        template = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.worker.run(sourceURL: url, perspective: perspective) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == currentOperationID else { return }
                        self.progress = value
                        self.phase = .scanning
                    }
                }
                guard self.operationID == currentOperationID else { return }
                self.index = result.index
                self.template = result.template
                self.phase = .ready
            } catch is CancellationError {
                if self.operationID == currentOperationID { self.phase = .idle }
            } catch {
                if self.operationID == currentOperationID { self.phase = .failed(error.localizedDescription) }
            }
            if self.operationID == currentOperationID {
                self.task = nil
                self.operationID = nil
            }
        }
    }

    func synthesize(session: ProjectSession, executor: WorkflowToolExecutor) {
        guard task == nil, let index, let template else { return }
        let currentOperationID = UUID()
        operationID = currentOperationID
        phase = .synthesizing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await executor.synthesizeTemplate(index: index, localTemplate: template, session: session)
                guard self.operationID == currentOperationID else { return }
                self.template = result
                self.phase = .completed
            } catch is CancellationError {
                if self.operationID == currentOperationID { self.phase = .ready }
            } catch {
                if self.operationID == currentOperationID { self.phase = .failed(error.localizedDescription) }
            }
            if self.operationID == currentOperationID {
                self.task = nil
                self.operationID = nil
            }
        }
    }

    func synthesize(settings: SettingsStore, executor: WorkflowToolExecutor) {
        guard task == nil, let index, let template else { return }
        let currentOperationID = UUID()
        operationID = currentOperationID
        phase = .synthesizing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await executor.synthesizeTemplate(index: index, localTemplate: template, settings: settings)
                guard self.operationID == currentOperationID else { return }
                self.template = result
                self.phase = .completed
            } catch is CancellationError {
                if self.operationID == currentOperationID { self.phase = .ready }
            } catch {
                if self.operationID == currentOperationID { self.phase = .failed(error.localizedDescription) }
            }
            if self.operationID == currentOperationID {
                self.task = nil
                self.operationID = nil
            }
        }
    }

    func markSaved() {
        if template != nil { phase = .completed }
    }

    func reset() {
        cancel()
        phase = .idle
        index = nil
        template = nil
    }

    func cancel() {
        operationID = nil
        task?.cancel()
        task = nil
        if phase == .copying || phase == .scanning || phase == .synthesizing { phase = .idle }
    }

    func deleteIndex(sourceHash: String) async throws {
        try await indexStore.delete(sourceHash: sourceHash)
    }
}
