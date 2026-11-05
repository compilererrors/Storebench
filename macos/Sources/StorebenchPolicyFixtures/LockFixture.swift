import Darwin
import Foundation
import StorebenchCore

/// Pure lock policy fixture. It never opens the app, a database, credentials or a network connection.
@main struct LockFixture {
    static func main() throws {
        let root = try TestIsolation.require(), args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 || args.count == 5 else { throw TestIsolation.Failure.unguarded }
        let urls = args.prefix(3).map { URL(fileURLWithPath: $0) }
        for url in urls { try TestIsolation.check(url) }
        guard urls.allSatisfy({ $0.path.hasPrefix(root.path + "/") }), urls[0].lastPathComponent.hasSuffix(".mutex") else { throw TestIsolation.Failure.outsideRoot }
        try FileMutex.withLock(urls[0]) {
            if args.count == 5 {
                guard args[3] == "--job-owner", args[4].range(of: #"\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z"#, options: .regularExpression) != nil,
                      urls[0].lastPathComponent.hasSuffix(".lock.mutex") else { throw TestIsolation.Failure.unguarded }
                let owner = urls[0].deletingPathExtension(); try TestIsolation.check(owner)
                let descriptor = open(owner.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw FileMutex.Failure.unavailable }
                let bytes = try JSONSerialization.data(withJSONObject: ["id": args[4], "pid": Int(getpid()), "protocol": 2])
                let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }; close(descriptor)
                guard written == bytes.count else { throw FileMutex.Failure.unavailable }
            }
            // Foundation's atomic replacement can use directories outside the owned run.
            // Readiness only signals the already-held kernel lock; create it directly here.
            let descriptor = open(urls[1].path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw FileMutex.Failure.unavailable }
            let marker = Array("held".utf8), written = write(descriptor, marker, marker.count)
            close(descriptor)
            guard written == marker.count else { throw FileMutex.Failure.unavailable }
            let deadline = ContinuousClock.now + .seconds(30)
            while !FileManager.default.fileExists(atPath: urls[2].path) {
                guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }
                Thread.sleep(forTimeInterval: 0.01)
            }
            // Synthetic interruption: close the process without running the lock defer.
            guard try String(contentsOf: urls[2], encoding: .utf8) == "interrupt" else { throw TestIsolation.Failure.unguarded }
            _exit(0)
        }
    }
}
