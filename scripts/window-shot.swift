// Captures the largest on-screen window of a process. Usage: swift window-shot.swift <pid> <out.png>
import Foundation
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let wins = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let w = wins.max(by: { a, b in
    let ra = a[kCGWindowBounds as String] as! [String: Double], rb = b[kCGWindowBounds as String] as! [String: Double]
    return ra["Width"]! * ra["Height"]! < rb["Width"]! * rb["Height"]!
}) else { print("no window"); exit(1) }
let id = w[kCGWindowNumber as String] as! Int
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-o", "-l", "\(id)", out]
try p.run(); p.waitUntilExit()
print("window \(id) -> \(out)")
