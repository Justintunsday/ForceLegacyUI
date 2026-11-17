import Foundation
import LegacyCore

enum BundleObservationCollector {
    static func collect(_ applications: [InstalledApplication], group: String, required: Set<String> = [],
                        log: inout String) -> [BundleSDKObservation] {
        var seen = Set<String>(), result: [BundleSDKObservation] = []
        let ownID = Bundle.main.bundleIdentifier
        func priority(_ app: InstalledApplication) -> Int { required.contains(app.bundleID) ? 0 : (app.bundleID == ownID ? 1 : 2) }
        let ordered = applications.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            return $0.bundleID < $1.bundleID
        }
        let began = ProcessInfo.processInfo.systemUptime
        var attempted = 0
        for app in ordered where LiveStorePolicy.bundlePath(app.bundlePath) && seen.insert(app.bundleID).inserted {
            if attempted >= 12 || ProcessInfo.processInfo.systemUptime - began >= 8 { break }
            attempted += 1
            let requestedPath = app.bundleID == ownID ? Bundle.main.bundlePath : app.bundlePath
            var error: NSError?
            guard let raw = FLInspectBundle(app.bundleID, requestedPath, group, &error),
                  let text = raw["sdk"] as? String, let sdk = SDKVersion(string: text),
                  let resolvedPath = raw["bundlePath"] as? String, LiveStorePolicy.bundlePath(resolvedPath),
                  let info = raw["infoData"] as? Data, let headers = raw["loadCommands"] as? Data else {
                log += "Bundle SDK \(app.bundleID), requested \(requestedPath), cache \(app.bundlePath): \(error?.localizedDescription ?? "metadata unavailable").\n"
                continue
            }
            result.append(BundleSDKObservation(bundleID: app.bundleID, bundlePath: resolvedPath, sdk: sdk,
                                                infoSHA256: sha256(info), loadCommandsSHA256: sha256(headers)))
            log += "Independent executable SDK \(app.bundleID): \(sdk); Info.plist identity and read stability checked; resolved \(resolvedPath).\n"
            if resolvedPath != app.bundlePath { log += "Registration spelling: \(app.bundlePath); resolved from directory entries or this app's own bundle.\n" }
        }
        log += "Bundle SDK observations: \(result.count), \(attempted) attempts; 12-attempt / 8-second budget between calls. Signed bundles were opened read-only.\n"
        return result.sorted { $0.bundleID < $1.bundleID }
    }
}
