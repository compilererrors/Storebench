// Writes bundle metadata for unsigned packaging with validated placeholder values.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil
}
func write(_ values: [String: Any], to path: String) {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0),
          FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o644]) else {
        fail("Could not write the package property list.")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 6 else { fail("Expected bundle ID, version, build, contact file, output and icon.") }
let (bundle, version, build, contactFile, out, icon) = (arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5])
guard matches(bundle, "[A-Za-z][A-Za-z0-9-]*(?:\\.[A-Za-z][A-Za-z0-9-]*)+"),
      version == "0.0.0", build == "1" else { fail("Unsigned packaging requires placeholder metadata.") }

let invalid = "Native package resources are invalid."
guard let data = FileManager.default.contents(atPath: contactFile),
      let contact = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let website = contact["website"] as? String, let url = URLComponents(string: website),
      url.scheme == "https", !(url.host ?? "").isEmpty, url.user == nil, url.password == nil,
      let support = contact["support"] as? String, let page = URLComponents(string: support),
      page.scheme == "https", !(page.host ?? "").isEmpty, page.user == nil, page.password == nil, page.query == nil,
      icon == "AppIcon.icns" else { fail(invalid) }
let values: [String: Any] = [
    "CFBundleIdentifier": bundle, "CFBundleName": "Storebench", "CFBundleDisplayName": "Storebench", "CFBundleExecutable": "Storebench",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build,
    "StorebenchDistribution": "prototype",
    "StorebenchSupportWebsite": website, "StorebenchSupportURL": support,
    "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": true,
    "CFBundleIconFile": icon,
    // Native drag tickets use an app-owned data type, without a file extension or document handler.
    "UTExportedTypeDeclarations": [["UTTypeIdentifier": "app.storebench.material-reorder", "UTTypeDescription": "Storebench material order", "UTTypeConformsTo": ["public.data"]]],
]
write(values, to: out)
