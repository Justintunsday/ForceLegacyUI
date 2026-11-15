import Foundation

public struct AppGroupResolution: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ready, renamed, missing, ambiguous }
    public let configured: String
    public let reportedGroups: [String]
    public let selected: String?
    public let state: State

    /// Accept only the configured group or a recognizable signing-tool rewrite of our own group.
    /// An unrelated group, even if accessible, must never have its Caches symlink changed.
    public static func candidates(configured: String, bundleID: String, reportedGroups: [String]) -> [String] {
        let roots = [configured, "group." + bundleID].filter(validIdentifier)
        let related = reportedGroups.filter { group in
            validIdentifier(group) && roots.contains { root in
                group == root || group.hasPrefix(root + ".") || group.hasSuffix("." + root)
                    || (root.hasPrefix("group.") && group.hasPrefix("group.") && group.hasSuffix("." + String(root.dropFirst(6))))
            }
        }
        return Array(Set(roots + related)).sorted()
    }

    public static func resolve(configured: String, bundleID: String, reportedGroups: [String],
                               accessibleGroups: Set<String>) -> AppGroupResolution {
        let eligible = candidates(configured: configured, bundleID: bundleID, reportedGroups: reportedGroups)
            .filter(accessibleGroups.contains)
        if eligible.contains(configured) {
            return .init(configured: configured, reportedGroups: reportedGroups, selected: configured, state: .ready)
        }
        if eligible.count == 1 {
            return .init(configured: configured, reportedGroups: reportedGroups, selected: eligible[0], state: .renamed)
        }
        return .init(configured: configured, reportedGroups: reportedGroups, selected: nil,
                     state: eligible.isEmpty ? .missing : .ambiguous)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.count > 6 && value.count <= 255 && value.contains("group.") && !value.contains("..") && !value.hasSuffix(".")
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
    }
}
