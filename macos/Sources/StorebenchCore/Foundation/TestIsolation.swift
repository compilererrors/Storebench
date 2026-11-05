import Darwin
import Foundation

/// The mandatory test isolation check. The runner owns the marker and temporary root.
public enum TestIsolation {
    public enum Failure: Error { case unguarded, outsideRoot }

    public static func require() throws -> URL {
        try require(ProcessInfo.processInfo.environment)
    }

    private static func require(_ environment: [String: String]) throws -> URL {
        guard environment["STOREBENCH_TEST_MODE"] == "1", let path = environment["STOREBENCH_TEST_ROOT"],
              let token = environment["STOREBENCH_TEST_TOKEN"], !token.isEmpty else { throw Failure.unguarded }
        guard let canonical = realPath(path) else { throw Failure.unguarded }
        let root = URL(fileURLWithPath: canonical, isDirectory: true)
        guard try String(contentsOf: root.appendingPathComponent(".test-run"), encoding: .utf8) == token else { throw Failure.unguarded }
        return root
    }

    public static func check(_ url: URL) throws {
        // One fresh snapshot per check; ownership and the marker are still read on every call.
        let environment = ProcessInfo.processInfo.environment
        guard environment["STOREBENCH_TEST_MODE"] == "1" else { return }
        let root = try require(environment).path
        let path = try canonicalPath(url.path)
        guard path == root || path.hasPrefix(root + "/") else { throw Failure.outsideRoot }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolve existing ancestors with the OS, including macOS's temporary-folder aliases.
    /// Foundation's URL resolver can return a different alias for an existing vs. missing file.
    private static func canonicalPath(_ path: String) throws -> String {
        var ancestor = path, suffix: [String] = []
        while true {
            if let canonical = realPath(ancestor) { return ([canonical] + suffix).joined(separator: "/") }
            var info = stat()
            // A dangling or inaccessible link is not evidence of a missing owned directory.
            guard lstat(ancestor, &info) != 0, errno == ENOENT,
                  let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex else { throw Failure.outsideRoot }
            let name = String(ancestor[ancestor.index(after: slash)...])
            guard !name.isEmpty, name != ".", name != ".." else { throw Failure.outsideRoot }
            suffix.insert(name, at: 0); ancestor = String(ancestor[..<slash])
        }
    }
}
