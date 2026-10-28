// 用法: swift scripts/make-icon.swift <source.png> <out.png>
// 生成 macOS 风格 App 图标：1024 画布，824×824 圆角方形居中（Big Sur 网格，
// 圆角半径 ≈ 边长 22.5%），源图缩放填入并按圆角裁切（外部全透明）。
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-icon.swift <source.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
guard let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("cannot read source image\n".data(using: .utf8)!)
    exit(1)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 824 * 0.225

let canvas = NSImage(size: canvasSize)
canvas.lockFocus()
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.saveGState()
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).addClip()
    // 覆盖像素比例：源图可能非正方形，按 aspect-fill 裁进 tile
    let srcSize = source.size
    let scale = max(tile.width / srcSize.width, tile.height / srcSize.height)
    let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
    let drawRect = NSRect(
        x: tile.midX - drawSize.width / 2,
        y: tile.midY - drawSize.height / 2,
        width: drawSize.width, height: drawSize.height)
    source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()
}
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: args[2]))
print("written \(args[2])")
