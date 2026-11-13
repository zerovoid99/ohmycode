import AppKit
import CoreText
import Metal
import simd

/// Instance layouts shared with the shaders in TerminalShaders.swift (pixel coordinates, top-left origin).
struct RectInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var color: SIMD4<Float>
    var isColor: UInt32 // stride 64, as in Metal (16-byte alignment)

    init(origin: SIMD2<Float>, size: SIMD2<Float>, uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>,
         color: SIMD4<Float>, isColor: Bool) {
        self.origin = origin
        self.size = size
        self.uvOrigin = uvOrigin
        self.uvSize = uvSize
        self.color = color
        self.isColor = isColor ? 1 : 0
    }
}

/// One frame's geometry: backgrounds first, then glyphs, then overlays (cursor, IME) on top.
struct TerminalFrame {
    var clearColor: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    var rects: [RectInstance] = []
    var glyphs: [GlyphInstance] = []
    var overlayRects: [RectInstance] = []
    var overlayGlyphs: [GlyphInstance] = []
}

/// Metal pipelines plus the glyph atlas. Shared by all terminal views (one device, one atlas
/// per font configuration).
@MainActor
final class TerminalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rectPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    let atlas: GlyphAtlas
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private static var sharedRenderer: TerminalRenderer??
    /// nil when Metal isn't available.
    static var shared: TerminalRenderer? {
        if let sharedRenderer { return sharedRenderer }
        let renderer = TerminalRenderer()
        sharedRenderer = .some(renderer)
        return renderer
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: TerminalShaders.source, options: nil) else { return nil }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Self.pixelFormat
            attachment.isBlendingEnabled = true // premultiplied alpha
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let rect = pipeline("rectVertex", "rectFragment"), let glyph = pipeline("glyphVertex", "glyphFragment"),
              let atlas = GlyphAtlas(device: device) else { return nil }
        self.device = device
        self.queue = queue
        rectPipeline = rect
        glyphPipeline = glyph
        self.atlas = atlas
    }

    /// Encodes `frame` into `texture` and commits. `completion` runs after the GPU finished.
    @discardableResult
    func render(_ frame: TerminalFrame, to texture: MTLTexture, drawable: MTLDrawable? = nil) -> MTLCommandBuffer? {
        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let c = frame.clearColor
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = SIMD2<Float>(Float(texture.width), Float(texture.height))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)

        func draw(rects: [RectInstance]) {
            guard !rects.isEmpty else { return }
            encoder.setRenderPipelineState(rectPipeline)
            setInstances(rects, encoder: encoder)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rects.count)
        }
        func draw(glyphs: [GlyphInstance]) {
            guard !glyphs.isEmpty else { return }
            encoder.setRenderPipelineState(glyphPipeline)
            setInstances(glyphs, encoder: encoder)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        draw(rects: frame.rects)
        draw(glyphs: frame.glyphs)
        draw(rects: frame.overlayRects)
        draw(glyphs: frame.overlayGlyphs)
        encoder.endEncoding()
        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
        return commandBuffer
    }

    /// Small batches go inline; larger ones in a buffer (Metal copies `bytes` either way).
    private func setInstances<T>(_ instances: [T], encoder: MTLRenderCommandEncoder) {
        let length = MemoryLayout<T>.stride * instances.count
        instances.withUnsafeBytes { raw in
            if length <= 4096 {
                encoder.setVertexBytes(raw.baseAddress!, length: length, index: 0)
            } else if let buffer = device.makeBuffer(bytes: raw.baseAddress!, length: length, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            }
        }
    }

    /// Renders offscreen and reads the pixels back (tests, screenshots).
    func snapshot(_ frame: TerminalFrame, width: Int, height: Int) -> NSBitmapImageRep? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = render(frame, to: texture) else { return nil }
        commandBuffer.waitUntilCompleted()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let data = bitmap.bitmapData else { return nil }
        texture.getBytes(data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for i in stride(from: 0, to: width * height * 4, by: 4) { swap(&data[i], &data[i + 2]) } // BGRA → RGBA
        return bitmap
    }
}

/// Glyphs rasterized once with CoreText into a shared texture, packed in shelves. Mono glyphs
/// are stored as white coverage (tinted in the shader); color glyphs (emoji) as-is.
@MainActor
final class GlyphAtlas {
    struct Key: Hashable {
        let text: String
        let font: String // PostScript name and size
        let scale: Int   // backing scale × 100
    }

    struct Glyph {
        /// Placement relative to the cell's left edge and baseline, in pixels (y down).
        let offset: SIMD2<Float>
        let size: SIMD2<Float>
        let uvOrigin: SIMD2<Float>
        let isColor: Bool
    }

    static let size = 2048
    let texture: MTLTexture
    private var glyphs: [Key: Glyph?] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0
    /// Bumped when the atlas is cleared; cached geometry referring to it must be rebuilt.
    private(set) var generation = 0

    init?(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.size,
                                                                  height: Self.size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    var glyphCount: Int { glyphs.count }

    /// The glyph for a grapheme, rasterizing it on first use; nil for blank text.
    func glyph(_ text: String, font: NSFont, scale: CGFloat) -> Glyph? {
        let key = Key(text: text, font: "\(font.fontName)@\(font.pointSize)", scale: Int(scale * 100))
        if let cached = glyphs[key] { return cached }
        let before = generation
        let glyph = rasterize(text, font: font, scale: scale)
        if generation == before { glyphs[key] = .some(glyph) } // not a failure caused by a full atlas
        return glyph
    }

    private func rasterize(_ text: String, font: NSFont, scale: CGFloat) -> Glyph? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let bounds = CTLineGetImageBounds(line, nil)
        guard !bounds.isEmpty, bounds.width.isFinite else { return nil }
        let isColor = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName] else { return false }
            return CTFontGetSymbolicTraits(runFont as! CTFont).contains(.traitColorGlyphs)
        }

        // Pixel box around the ink, 1px margin for antialiasing.
        let minX = floor(bounds.minX * scale) - 1, minY = floor(bounds.minY * scale) - 1
        let width = Int(ceil(bounds.maxX * scale) + 1 - minX), height = Int(ceil(bounds.maxY * scale) + 1 - minY)
        guard width > 0, height > 0, width < Self.size, height < Self.size else { return nil }
        guard let origin = allocate(width: width, height: height) else {
            reset()
            return nil // the caller rebuilds after a reset (see `generation`)
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.setAllowsFontSmoothing(false)
            context.setShouldAntialias(true)
            context.setAllowsFontSubpixelPositioning(false)
            context.translateBy(x: -minX, y: -minY)
            context.scaleBy(x: scale, y: scale)
            if !isColor {
                // White text: alpha is the coverage.
                let white = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
                CTLineDraw(CTLineCreateWithAttributedString(white), context)
            } else {
                CTLineDraw(line, context)
            }
        }
        texture.replace(region: MTLRegionMake2D(origin.x, origin.y, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bytesPerRow)
        // CG's y axis points up from the baseline; ours points down.
        return Glyph(offset: SIMD2(Float(minX), Float(-(minY + CGFloat(height)))),
                     size: SIMD2(Float(width), Float(height)),
                     uvOrigin: SIMD2(Float(origin.x), Float(origin.y)), isColor: isColor)
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if shelfX + width > Self.size {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        guard shelfY + height <= Self.size else { return nil }
        let origin = (shelfX, shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return origin
    }

    /// Full: start over. Glyphs are re-rasterized as rows are rebuilt.
    func reset() {
        glyphs.removeAll()
        shelfX = 0; shelfY = 0; shelfHeight = 0
        generation += 1
    }
}
