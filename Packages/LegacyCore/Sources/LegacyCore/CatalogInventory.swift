import Foundation

public struct ReconciledCatalog: Sendable {
    public let applications: [InstalledApplication]
    public let addedFromCache: Int
    public let filledMissingPaths: Int
    public let excludedConflicts: Int
}

/// Partial native enumeration must not suppress independently observed cache registrations.
/// Cache paths remain labelled as such; a cache SDK is never promoted to native evidence.
public enum CatalogInventory {
    public static func reconcile(native: [InstalledApplication], registrations: [InstalledApplication]) throws -> ReconciledCatalog {
        guard native.count <= 10000, registrations.count <= 10000 else {
            throw LegacyError.unsupported("Application inventory exceeds its bounded record limit.")
        }
        let nativeGroups = Dictionary(grouping: native, by: \.bundleID)
        let cacheGroups = Dictionary(grouping: registrations, by: \.bundleID)
        var result: [InstalledApplication] = [], added = 0, filled = 0, conflicts = 0
        for id in Set(nativeGroups.keys).union(cacheGroups.keys).sorted() {
            let a = nativeGroups[id, default: []], b = cacheGroups[id, default: []]
            guard a.count <= 1, b.count <= 1 else { conflicts += 1; continue }
            let observed = a.first
            guard let cached = b.first, LiveStorePolicy.bundlePath(cached.bundlePath) else {
                if let observed { result.append(observed) }
                continue
            }
            if let observed, !observed.bundlePath.isEmpty {
                guard LiveStorePolicy.sameBundleRegistration(observed.bundlePath, cached.bundlePath) else {
                    conflicts += 1; continue
                }
                result.append(observed)
            } else {
                result.append(InstalledApplication(bundleID: id,
                    name: observed.flatMap { $0.name.isEmpty ? nil : $0.name } ?? cached.name,
                    bundlePath: cached.bundlePath, reportedSDK: nil,
                    applicationType: "Cache registration (read-only)"))
                if observed == nil { added += 1 } else { filled += 1 }
            }
        }
        return ReconciledCatalog(applications: result, addedFromCache: added,
                                 filledMissingPaths: filled, excludedConflicts: conflicts)
    }
}
