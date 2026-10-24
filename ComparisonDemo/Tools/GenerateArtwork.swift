import CoreGraphics
import Foundation
import ImageIO

// The app ships these generated illustrations so both lists use the same offline sources.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let palettes: [[Double]] = [
    [0.76, 0.85, 0.85, 0.28, 0.42, 0.38],
    [0.89, 0.80, 0.68, 0.40, 0.39, 0.31],
    [0.67, 0.79, 0.87, 0.23, 0.37, 0.44],
    [0.84, 0.80, 0.76, 0.39, 0.36, 0.43],
    [0.79, 0.84, 0.72, 0.30, 0.41, 0.26],
    [0.91, 0.79, 0.70, 0.49, 0.35, 0.30],
]
for index in 0..<24 {
    let width = 1280
    let height = 800
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let p = palettes[index % palettes.count]
    let sky = CGColor(red: p[0], green: p[1], blue: p[2], alpha: 1)
    let pale = CGColor(
        red: min(1, p[0] + 0.12),
        green: min(1, p[1] + 0.1),
        blue: min(1, p[2] + 0.08),
        alpha: 1
    )
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [pale, sky] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    context.setFillColor(CGColor(red: 0.99, green: 0.92, blue: 0.75, alpha: 0.95))
    let sunX = 190 + (index * 137) % 900
    context.fillEllipse(in: CGRect(x: sunX, y: 505, width: 105, height: 105))
    for ridge in 0..<4 {
        let lift = Double(3 - ridge) * 100
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -50, y: 0))
        path.addLine(to: CGPoint(x: -50, y: 230 + lift))
        for point in 0..<9 {
            let x = Double(point) * 180 - 50
            let wave = sin(Double(point * 3 + index + ridge) * 0.8) * 85
            path.addLine(to: CGPoint(x: x, y: 230 + lift + wave))
        }
        path.addLine(to: CGPoint(x: 1400, y: 0))
        path.closeSubpath()
        let haze = Double(3 - ridge) * 0.11
        context.setFillColor(
            CGColor(red: p[3] + haze, green: p[4] + haze, blue: p[5] + haze, alpha: 1)
        )
        context.addPath(path)
        context.fillPath()
    }
    // Water and a winding trail give each illustration a recognizable foreground.
    let water = CGMutablePath()
    water.move(to: CGPoint(x: 250, y: 0))
    water.addCurve(
        to: CGPoint(x: 850, y: 235),
        control1: CGPoint(x: 900, y: 10),
        control2: CGPoint(x: 500, y: 130)
    )
    water.addCurve(
        to: CGPoint(x: 1010, y: 0),
        control1: CGPoint(x: 1100, y: 160),
        control2: CGPoint(x: 1150, y: 80)
    )
    water.closeSubpath()
    context.addPath(water)
    context.setFillColor(CGColor(red: p[0] * 0.78, green: p[1] * 0.85, blue: p[2] * 0.9, alpha: 1))
    context.fillPath()
    for tree in 0..<20 {
        let x = Double((tree * 97 + index * 43) % 1280)
        let y = Double((tree * 37 + index * 11) % 110)
        let h = Double(35 + (tree * 13) % 70)
        let treePath = CGMutablePath()
        treePath.move(to: CGPoint(x: x, y: y + h))
        treePath.addLine(to: CGPoint(x: x - h * 0.3, y: y))
        treePath.addLine(to: CGPoint(x: x + h * 0.3, y: y))
        treePath.closeSubpath()
        context.addPath(treePath)
        context.setFillColor(
            CGColor(red: p[3] * 0.55, green: p[4] * 0.6, blue: p[5] * 0.6, alpha: 0.8)
        )
        context.fillPath()
    }
    let image = context.makeImage()!
    let url = destination.appendingPathComponent("landscape-\(index).jpg")
    let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(
        writer,
        image,
        [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
    )
    precondition(CGImageDestinationFinalize(writer))
}

let assets = destination.deletingLastPathComponent().appendingPathComponent(
    "Assets.xcassets",
    isDirectory: true
)
let iconFolder = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconFolder, withIntermediateDirectories: true)
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}".write(
    to: assets.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
try
    "{\"images\":[{\"filename\":\"AppIcon.png\",\"idiom\":\"universal\",\"platform\":\"ios\",\"size\":\"1024x1024\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}"
    .write(
        to: iconFolder.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )
let icon = CGContext(
    data: nil,
    width: 1024,
    height: 1024,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
icon.setFillColor(CGColor(red: 0.20, green: 0.38, blue: 0.30, alpha: 1))
icon.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
for column in 0..<2 {
    let x = Double(170 + column * 360)
    icon.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1))
    icon.addPath(
        CGPath(
            roundedRect: CGRect(x: x, y: 210, width: 300, height: 604),
            cornerWidth: 44,
            cornerHeight: 44,
            transform: nil
        )
    )
    icon.fillPath()
    for row in 0..<4 {
        icon.setFillColor(CGColor(red: 0.20, green: 0.38, blue: 0.30, alpha: row == 0 ? 0.7 : 0.22))
        icon.addPath(
            CGPath(
                roundedRect: CGRect(x: x + 38, y: Double(650 - row * 112), width: 224, height: 60),
                cornerWidth: 14,
                cornerHeight: 14,
                transform: nil
            )
        )
        icon.fillPath()
    }
}
let iconWriter = CGImageDestinationCreateWithURL(
    iconFolder.appendingPathComponent("AppIcon.png") as CFURL,
    "public.png" as CFString,
    1,
    nil
)!
CGImageDestinationAddImage(iconWriter, icon.makeImage()!, nil)
precondition(CGImageDestinationFinalize(iconWriter))
