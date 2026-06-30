import Cocoa

// Renders a 1024x1024 app icon: a dark rounded "squircle" with a bright green
// battery and a lightning bolt. Output: icon_1024.png in the cwd.

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no ctx")
}
let s = CGFloat(S)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    return CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

// --- background squircle (leave a margin like real macOS icons) ---
let margin = s * 0.085
let bg = CGRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
let bgRadius = bg.width * 0.2237
let bgPath = CGPath(roundedRect: bg, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
    colors: [rgb(38, 44, 56), rgb(15, 18, 24)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// subtle top highlight
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
ctx.setFillColor(rgb(255, 255, 255, 0.05))
ctx.fill(CGRect(x: bg.minX, y: bg.midY, width: bg.width, height: bg.height/2))
ctx.restoreGState()

// --- battery body ---
let bw = bg.width * 0.60
let bh = bg.height * 0.34
let bx = bg.midX - bw/2 - bg.width*0.02
let by = bg.midY - bh/2
let body = CGRect(x: bx, y: by, width: bw, height: bh)
let bodyR = bh * 0.22
let lw = s * 0.026

// outline
ctx.setStrokeColor(rgb(230, 233, 239))
ctx.setLineWidth(lw)
let bodyPath = CGPath(roundedRect: body, cornerWidth: bodyR, cornerHeight: bodyR, transform: nil)
ctx.addPath(bodyPath)
ctx.strokePath()

// terminal nub
let nubW = bg.width * 0.045
let nubH = bh * 0.42
let nub = CGRect(x: body.maxX + lw*0.3, y: bg.midY - nubH/2, width: nubW, height: nubH)
let nubPath = CGPath(roundedRect: nub, cornerWidth: nubW*0.4, cornerHeight: nubW*0.4, transform: nil)
ctx.setFillColor(rgb(230, 233, 239))
ctx.addPath(nubPath)
ctx.fillPath()

// green charge fill (inside the body, with padding)
let pad = lw * 1.25
let fillMax = body.insetBy(dx: pad, dy: pad)
let fillW = fillMax.width * 0.70
let fill = CGRect(x: fillMax.minX, y: fillMax.minY, width: fillW, height: fillMax.height)
let fillR = bodyR * 0.6
let fillPath = CGPath(roundedRect: fill, cornerWidth: fillR, cornerHeight: fillR, transform: nil)
let gFill = CGGradient(colorsSpace: cs,
    colors: [rgb(90, 222, 120), rgb(38, 178, 86)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(fillPath)
ctx.clip()
ctx.drawLinearGradient(gFill, start: CGPoint(x: 0, y: fill.maxY), end: CGPoint(x: 0, y: fill.minY), options: [])
ctx.restoreGState()

// --- lightning bolt (white, centered on the body) ---
let cx = body.midX
let cy = body.midY
let hw = bw * 0.16
let hh = bh * 0.40
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: cx + 0.15*hw, y: cy + hh))
bolt.addLine(to: CGPoint(x: cx - 0.70*hw, y: cy - 0.12*hh))
bolt.addLine(to: CGPoint(x: cx - 0.05*hw, y: cy - 0.12*hh))
bolt.addLine(to: CGPoint(x: cx - 0.15*hw, y: cy - hh))
bolt.addLine(to: CGPoint(x: cx + 0.70*hw, y: cy + 0.16*hh))
bolt.addLine(to: CGPoint(x: cx + 0.05*hw, y: cy + 0.16*hh))
bolt.closeSubpath()
// white bolt with a soft dark edge so it reads on the green
ctx.setShadow(offset: .zero, blur: s*0.012, color: rgb(0,0,0,0.35))
ctx.setFillColor(rgb(255, 255, 255))
ctx.addPath(bolt)
ctx.fillPath()

// --- write PNG ---
guard let img = ctx.makeImage() else { fatalError("no image") }
let outURL = URL(fileURLWithPath: "icon_1024.png")
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("no dest")
}
CGImageDestinationAddImage(dest, img, nil)
if CGImageDestinationFinalize(dest) {
    print("wrote icon_1024.png")
} else {
    fatalError("failed to write png")
}
