#!/usr/bin/swift
import Foundation

let appPath = CommandLine.arguments.dropFirst().first ?? "/Applications/Codeboard.app"
let appURL = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
let fileManager = FileManager.default

guard fileManager.fileExists(atPath: appURL.path) else {
    fputs("App bundle not found at \(appURL.path)\n", stderr)
    exit(1)
}

let dockPlist = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Preferences/com.apple.dock.plist")

var format = PropertyListSerialization.PropertyListFormat.binary
let dockData = try Data(contentsOf: dockPlist)
guard var root = try PropertyListSerialization.propertyList(
    from: dockData,
    options: [.mutableContainersAndLeaves],
    format: &format
) as? [String: Any] else {
    fputs("Could not read Dock preferences\n", stderr)
    exit(1)
}

guard var persistentApps = root["persistent-apps"] as? [[String: Any]] else {
    fputs("Dock preferences do not contain persistent-apps\n", stderr)
    exit(1)
}

func tileData(_ tile: [String: Any]) -> [String: Any] {
    tile["tile-data"] as? [String: Any] ?? [:]
}

func fileLabel(_ tile: [String: Any]) -> String? {
    tileData(tile)["file-label"] as? String
}

func bundleIdentifier(_ tile: [String: Any]) -> String? {
    tileData(tile)["bundle-identifier"] as? String
}

func fileURLString(_ tile: [String: Any]) -> String? {
    (tileData(tile)["file-data"] as? [String: Any])?["_CFURLString"] as? String
}

func matchesCodeboard(_ tile: [String: Any]) -> Bool {
    if bundleIdentifier(tile) == "com.jackdigilov.codeboard" { return true }
    if fileLabel(tile) == "Codeboard" { return true }
    return fileURLString(tile)?.contains("/Codeboard.app/") == true
}

persistentApps.removeAll(where: matchesCodeboard)

let bookmarkData = try appURL.bookmarkData(
    options: [.suitableForBookmarkFile],
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)

let now = Int(Date().timeIntervalSinceReferenceDate)
let codeboardTile: [String: Any] = [
    "GUID": UInt32.random(in: UInt32.min...UInt32.max),
    "tile-data": [
        "book": bookmarkData,
        "bundle-identifier": "com.jackdigilov.codeboard",
        "dock-extra": false,
        "file-data": [
            "_CFURLString": appURL.absoluteString,
            "_CFURLStringType": 15,
        ],
        "file-label": "Codeboard",
        "file-mod-date": now,
        "file-type": 41,
        "is-beta": false,
        "parent-mod-date": now,
    ],
    "tile-type": "file-tile",
]

if let ghosttyIndex = persistentApps.firstIndex(where: {
    fileLabel($0) == "Ghostty" || bundleIdentifier($0) == "com.mitchellh.ghostty"
}) {
    persistentApps.insert(codeboardTile, at: persistentApps.index(after: ghosttyIndex))
} else if let cmuxIndex = persistentApps.firstIndex(where: {
    fileLabel($0) == "cmux" || bundleIdentifier($0) == "com.cmuxterm.app"
}) {
    persistentApps.insert(codeboardTile, at: cmuxIndex)
} else {
    persistentApps.append(codeboardTile)
}

root["persistent-apps"] = persistentApps

let dateStamp = ISO8601DateFormatter()
    .string(from: Date())
    .replacingOccurrences(of: ":", with: "-")
let backupURL = dockPlist.deletingLastPathComponent()
    .appendingPathComponent("com.apple.dock.plist.codeboard-backup-\(dateStamp)")
try? fileManager.copyItem(at: dockPlist, to: backupURL)

let updatedData = try PropertyListSerialization.data(
    fromPropertyList: root,
    format: .binary,
    options: 0
)
try updatedData.write(to: dockPlist, options: .atomic)

print("Inserted Codeboard into Dock preferences after Ghostty.")
print("Backup: \(backupURL.path)")
