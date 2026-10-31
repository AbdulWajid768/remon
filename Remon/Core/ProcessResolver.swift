import Darwin
import Foundation

/// Maps PIDs to app identities (bundle name, path, system flag). Results are cached per PID.
actor ProcessResolver {
    private struct Entry {
        var comm: String
        var identity: AppIdentity
        var grouped: Bool
    }

    private var cache: [Int32: Entry] = [:]

    func identities(for processes: [(pid: Int32, name: String)], groupHelpers: Bool) -> [Int32: AppIdentity] {
        var result: [Int32: AppIdentity] = [:]
        for (pid, name) in processes {
            if let entry = cache[pid], entry.comm == name, entry.grouped == groupHelpers {
                result[pid] = entry.identity
                continue
            }
            let identity = Self.resolve(pid: pid, comm: name, groupHelpers: groupHelpers)
            cache[pid] = Entry(comm: name, identity: identity, grouped: groupHelpers)
            result[pid] = identity
        }
        return result
    }

    /// Drops cache entries for PIDs no longer reported.
    func prune(keeping pids: Set<Int32>) {
        cache = cache.filter { pids.contains($0.key) }
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cBuffer: buffer)
    }

    static func resolve(pid: Int32, comm: String, groupHelpers: Bool) -> AppIdentity {
        guard let path = executablePath(pid: pid) else {
            let isKernel = pid == 0 || comm == "kernel_task"
            return AppIdentity(id: "proc:\(comm)", name: isKernel ? "macOS Kernel" : comm,
                               bundleID: nil, bundlePath: nil, executablePath: nil, isSystem: isKernel)
        }
        let bundlePath = enclosingBundle(of: path, outermost: groupHelpers)
        let bundle = bundlePath.flatMap { Bundle(path: $0) }
        let bundleID = bundle?.bundleIdentifier
        let name: String
        if let bundlePath {
            name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? FileManager.default.displayName(atPath: bundlePath).replacingOccurrences(of: ".app", with: "")
        } else {
            name = (path as NSString).lastPathComponent
        }
        let isSystem = path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/Library/Apple/") || (bundleID?.hasPrefix("com.apple.") ?? false)
        return AppIdentity(id: bundlePath ?? path, name: name, bundleID: bundleID, bundlePath: bundlePath,
                           executablePath: path, isSystem: isSystem)
    }

    /// `/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper`
    /// → `/Applications/Foo.app` (outermost) or `…/Foo Helper.app` (innermost).
    static func enclosingBundle(of path: String, outermost: Bool) -> String? {
        let components = path.components(separatedBy: "/")
        let indices = components.indices.filter { components[$0].hasSuffix(".app") }
        guard let index = outermost ? indices.first : indices.last else { return nil }
        return components[...index].joined(separator: "/")
    }
}
