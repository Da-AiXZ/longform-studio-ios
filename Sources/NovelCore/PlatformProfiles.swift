import Foundation

public enum BuiltInPlatformProfiles {
    public static let notice = "这是可编辑的创作启发与质量基线，不是平台官方审核规则。投稿前请核对平台当前规则。"

    public static let qidian = PlatformProfile(
        id: PublishingPlatform.qidian.rawValue,
        name: PublishingPlatform.qidian.displayName,
        notice: notice,
        weights: [
            .plotCausality: 0.20,
            .continuity: 0.20,
            .character: 0.15,
            .longTermStructure: 0.15,
            .prose: 0.15,
            .hookPayoff: 0.10,
            .originality: 0.05
        ]
    )

    public static let fanqie = PlatformProfile(
        id: PublishingPlatform.fanqie.rawValue,
        name: PublishingPlatform.fanqie.displayName,
        notice: notice,
        weights: [
            .pacing: 0.20,
            .conflictEmotion: 0.20,
            .hookPayoff: 0.20,
            .character: 0.15,
            .plotCausality: 0.10,
            .readability: 0.10,
            .originality: 0.05
        ]
    )

    public static func profile(for platform: PublishingPlatform) -> PlatformProfile {
        switch platform {
        case .qidian: return qidian
        case .fanqie: return fanqie
        }
    }
}
