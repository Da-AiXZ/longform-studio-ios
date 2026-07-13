import Foundation
import Combine
import NovelCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var projects: [NovelProject] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    let repository: ProjectRepository
    let settings: SettingsStore

    init(repository: ProjectRepository, settings: SettingsStore) {
        self.repository = repository
        self.settings = settings
    }

    static func live() -> AppStore {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = base.appendingPathComponent("LongformStudio/Projects", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") {
            try? manager.removeItem(at: root.deletingLastPathComponent())
            UserDefaults.standard.removeObject(forKey: "settings.v1")
        }
        return AppStore(repository: ProjectRepository(rootURL: root), settings: SettingsStore())
    }

    func loadProjects() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await repository.listProjects()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await DiagnosticLogger.shared.log(category: "Storage", message: error.localizedDescription)
        }
    }

    func createProject(_ project: NovelProject) async -> ProjectSession? {
        do {
            let workspace = try await repository.createProject(project)
            await loadProjects()
            return ProjectSession(workspace: workspace, repository: repository, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openProject(id: UUID) async -> ProjectSession? {
        do {
            let workspace = try await repository.loadProject(id: id)
            return ProjectSession(workspace: workspace, repository: repository, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importFile(_ url: URL) async -> ProjectSession? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let workspace: ProjectWorkspace
            if url.pathExtension.lowercased() == "novelproj" {
                workspace = try await repository.importArchive(data)
            } else {
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                workspace = try await repository.importManuscript(title: url.deletingPathExtension().lastPathComponent, text: text)
            }
            await loadProjects()
            return ProjectSession(workspace: workspace, repository: repository, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteProject(id: UUID) async {
        do {
            try await repository.deleteProject(id: id)
            await loadProjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
