import Foundation
import LegacyCore

enum BundleObservationCollector {
    static func collect(_ applications: [InstalledApplication], group: String, required: Set<String> = [],
                        log: inout String) -> [BundleSDKObservation] {
        var seen = Set<String>(), result: [BundleSDKObservation] = []
        let ordered = applications.sorted {
            if required.contains($0.bundleID) != required.contains($1.bundleID) { return required.contains($0.bundleID) }
            return $0.bundleID < $1.bundleID
        }
        let began = ProcessInfo.processInfo.systemUptime
        var attempted = 0
        for app in ordered where LiveStorePolicy.bundlePath(app.bundlePath) && seen.insert(app.bundleID).inserted {
            if attempted >= 12 || ProcessInfo.processInfo.systemUptime - began >= 8 { break }
            attempted += 1
            var error: NSError?
            guard let raw = FLInspectBundle(app.bundleID, app.bundlePath, group, &error),
                  let text = raw["sdk"] as? String, let sdk = SDKVersion(string: text),
                  let info = raw["infoData"] as? Data, let headers = raw["loadCommands"] as? Data else {
                log += "Bundle SDK \(app.bundleID): \(error?.localizedDescription ?? "metadata unavailable").\n"
                continue
            }
            result.append(BundleSDKObservation(bundleID: app.bundleID, bundlePath: app.bundlePath, sdk: sdk,
                                                infoSHA256: sha256(info), loadCommandsSHA256: sha256(headers)))
            log += "Independent executable SDK \(app.bundleID): \(sdk); Info.plist identity and read stability checked.\n"
        }
        log += "Bundle SDK observations: \(result.count), \(attempted) attempts; 12-attempt / 8-second budget between calls. Signed bundles were opened read-only.\n"
        return result.sorted { $0.bundleID < $1.bundleID }
    }
}
