#!/usr/bin/env swift
// 开发工具：按 owner 名找 CGWindowID，供 `screencapture -l` 捕获单窗口。
// 用法: swift scripts/window-id.swift <应用进程名> [标题包含]
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Dictately"
let titleNeedle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fatalError("CGWindowListCopyWindowInfo failed")
}
for info in infos {
    guard let ownerName = info[kCGWindowOwnerName as String] as? String,
          ownerName == owner,
          let windowID = info[kCGWindowNumber as String] as? Int else { continue }
    let title = (info[kCGWindowName as String] as? String) ?? ""
    let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
    guard layer == 0 else { continue } // 仅普通窗口
    if let needle = titleNeedle, !title.contains(needle) { continue }
    print(windowID)
    exit(0)
}
fatalError("window not found for owner \(owner)")
