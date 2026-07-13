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
    }

    @Published var profiles: [AIEndpointProfile] { didSet { persist() } }
    @Published var assignments: RoleAssignments { didSet { persist() } }
    @Published var platformProfiles: [PlatformProfile] { didSet { persist() } }
    @Published var blindPreferences: [String: Int] { didSet { persist() } }

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
        } else {
            profiles = []
            assignments = RoleAssignments()
            platformProfiles = [BuiltInPlatformProfiles.qidian, BuiltInPlatformProfiles.fanqie]
            blindPreferences = [:]
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

    private func persist() {
        guard !isLoading else { return }
        let payload = Payload(profiles: profiles, assignments: assignments, platformProfiles: platformProfiles, blindPreferences: blindPreferences)
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
