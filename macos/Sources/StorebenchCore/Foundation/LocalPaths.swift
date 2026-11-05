import Darwin
import Foundation

enum LocalPaths {
    /// Absolute path normalization is lexical here. Foundation may rewrite macOS aliases
    /// depending on whether a file exists, which would change a saved Keychain identity.
    static func lexical(_ url: URL) -> String {
        var parts: [String] = []
        for part in url.path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(String(part)) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Physical identity for overlap checks, including targets that have not been created yet.
    static func canonical(_ url: URL) -> String? {
        var path = url.path, suffix: [String] = []
        while true {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + suffix).joined(separator: "/")
            }
            var info = stat()
            guard lstat(path, &info) != 0, errno == ENOENT, let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return nil }
            let name = String(path[path.index(after: slash)...])
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            suffix.insert(name, at: 0); path = String(path[..<slash])
        }
    }
}
