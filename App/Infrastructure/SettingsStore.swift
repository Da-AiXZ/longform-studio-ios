import Foundation
import Combine
import NovelCore

@MainActor
final class SettingsStore: ObservableObject {
    private struct Payload: Codable {
        var profiles: [AIEndpointProfile]
        var assignments: RoleAssignments
        var platformProfiles: [PlatformProfile]
        var blindPreferences: [String: Int]
        var writingTemplates: [WritingTemplate]

        enum CodingKeys: String, CodingKey {
            case profiles, assignments, platformProfiles, blindPreferences, writingTemplates
        }

        init(profiles: [AIEndpointProfile], assignments: RoleAssignments, platformProfiles: [PlatformProfile], blindPreferences: [String: Int], writingTemplates: [WritingTemplate]) {
            self.profiles = profiles
            self.assignments = assignments
            self.platformProfiles = platformProfiles
            self.blindPreferences = blindPreferences
            self.writingTemplates = writingTemplates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try container.decodeIfPresent([AIEndpointProfile].self, forKey: .profiles) ?? []
            assignments = try container.decodeIfPresent(RoleAssignments.self, forKey: .assignments) ?? RoleAssignments()
            platformProfiles = try container.decodeIfPresent([PlatformProfile].self, forKey: .platformProfiles) ?? [BuiltInPlatformProfiles.qidian, BuiltInPlatformProfiles.fanqie]
            blindPreferences = try container.decodeIfPresent([String: Int].self, forKey: .blindPreferences) ?? [:]
            writingTemplates = try container.decodeIfPresent([WritingTemplate].self, forKey: .writingTemplates) ?? []
        }
    }

    @Published var profiles: [AIEndpointProfile] { didSet { persist() } }
    @Published var assignments: RoleAssignments { didSet { persist() } }
    @Published var platformProfiles: [PlatformProfile] { didSet { persist() } }
    @Published var blindPreferences: [String: Int] { didSet { persist() } }
    @Published var writingTemplates: [WritingTemplate] { didSet { persist() } }

    let keychain = KeychainStore()
    private let defaults: UserDefaults
    private let storageKey = "settings.v1"
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey), let payload = try? JSONDecoder.iso8601.decode(Payload.self, from: data) {
            profiles = payload.profiles
            assignments = payload.assignments
            platformProfiles = payload.platformProfiles
            blindPreferences = payload.blindPreferences
            writingTemplates = payload.writingTemplates
        } else {
            profiles = []
            assignments = RoleAssignments()
            platformProfiles = [BuiltInPlatformProfiles.qidian, BuiltInPlatformProfiles.fanqie]
            blindPreferences = [:]
            writingTemplates = []
        }
        isLoading = false
    }

    func profile(for role: AIRole) -> AIEndpointProfile? {
        guard let id = assignments.assignments[role] else { return profiles.first }
        return profiles.first { $0.id == id } ?? profiles.first
    }

    func platformProfile(for platform: PublishingPlatform) -> PlatformProfile {
        platformProfiles.first { $0.id == platform.rawValue } ?? BuiltInPlatformProfiles.profile(for: platform)
    }

    func save(profile: AIEndpointProfile, apiKey: String?) throws {
        guard profile.isSecure else { throw AIClientError.insecureEndpoint }
        if let apiKey, !apiKey.isEmpty { try keychain.set(apiKey, for: profile.keychainReference) }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    func delete(profile: AIEndpointProfile) throws {
        profiles.removeAll { $0.id == profile.id }
        assignments.assignments = assignments.assignments.filter { $0.value != profile.id }
        try keychain.remove(reference: profile.keychainReference)
    }

    func save(template: WritingTemplate) {
        if let index = writingTemplates.firstIndex(where: { $0.id == template.id }) {
            writingTemplates[index] = template
        } else {
            writingTemplates.append(template)
        }
        writingTemplates.sort { $0.createdAt > $1.createdAt }
    }

    func delete(templateID: UUID) {
        writingTemplates.removeAll { $0.id == templateID }
    }

    private func persist() {
        guard !isLoading else { return }
        let payload = Payload(profiles: profiles, assignments: assignments, platformProfiles: platformProfiles, blindPreferences: blindPreferences, writingTemplates: writingTemplates)
        if let data = try? JSONEncoder.iso8601.encode(payload) { defaults.set(data, forKey: storageKey) }
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
