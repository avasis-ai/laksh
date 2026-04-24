import Foundation
import CoreText
import CoreGraphics
import Metal

/// Font atlas for GPU text rendering
/// Caches glyph bitmaps in a Metal texture atlas
final class FontAtlas {
    
    struct GlyphInfo {
        let textureRect: CGRect   // UV rect in atlas (0-1)
        let size: CGSize          // Glyph size in pixels
        let bearing: CGPoint      // Offset from baseline
        let advance: CGFloat      // Horizontal advance
    }
    
    private let device: MTLDevice
    private(set) var texture: MTLTexture?
    private var glyphCache: [GlyphKey: GlyphInfo] = [:]
    
    private let font: CTFont
    private let boldFont: CTFont
    private let italicFont: CTFont
    
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let baseline: CGFloat
    
    private var atlasWidth: Int = 1024
    private var atlasHeight: Int = 1024
    private var packX: Int = 0
    private var packY: Int = 0
    private var rowHeight: Int = 0
    
    private struct GlyphKey: Hashable {
        let character: Character
        let bold: Bool
        let italic: Bool
    }
    
    init(device: MTLDevice, fontName: String = "SF Mono", fontSize: CGFloat = 13) {
        self.device = device
        
        // Create fonts
        let descriptor = CTFontDescriptorCreateWithNameAndSize(fontName as CFString, fontSize)
        self.font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        
        // Bold variant
        var boldTraits = CTFontSymbolicTraits.boldTrait
        if let boldDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, boldTraits, boldTraits
        ) {
            self.boldFont = CTFontCreateWithFontDescriptor(boldDescriptor, fontSize, nil)
        } else {
            self.boldFont = font
        }
        
        // Italic variant
        var italicTraits = CTFontSymbolicTraits.italicTrait
        if let italicDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, italicTraits, italicTraits
        ) {
            self.italicFont = CTFontCreateWithFontDescriptor(italicDescriptor, fontSize, nil)
        } else {
            self.italicFont = font
        }
        
        // Calculate cell metrics from 'M' glyph
        let metrics = Self.measureGlyph("M", font: font)
        self.cellWidth = ceil(metrics.advance)
        self.cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        self.baseline = CTFontGetDescent(font)
        
        // Create initial atlas texture
        createAtlasTexture()
        
        // Pre-cache ASCII printable characters
        precacheASCII()
    }
    
    private func createAtlasTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        
        texture = device.makeTexture(descriptor: descriptor)
    }
    
    private func precacheASCII() {
        for code in 32...126 {
            let char = Character(UnicodeScalar(code)!)
            _ = glyph(for: char, bold: false, italic: false)
            _ = glyph(for: char, bold: true, italic: false)
            _ = glyph(for: char, bold: false, italic: true)
        }
    }
    
    func glyph(for character: Character, bold: Bool = false, italic: Bool = false) -> GlyphInfo? {
        let key = GlyphKey(character: character, bold: bold, italic: italic)
        
        if let cached = glyphCache[key] {
            return cached
        }
        
        let selectedFont: CTFont
        if bold && italic {
            // Try bold-italic, fall back to bold
            selectedFont = boldFont
        } else if bold {
            selectedFont = boldFont
        } else if italic {
            selectedFont = italicFont
        } else {
            selectedFont = font
        }
        
        guard let info = rasterizeGlyph(character, font: selectedFont) else {
            return nil
        }
        
        glyphCache[key] = info
        return info
    }
    
    private func rasterizeGlyph(_ character: Character, font: CTFont) -> GlyphInfo? {
        let string = String(character) as CFString
        let attrString = CFAttributedStringCreate(
            nil,
            string,
            [kCTFontAttributeName: font] as CFDictionary
        )!
        
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        
        guard let run = runs.first else { return nil }
        
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        
        var advance = CGSize()
        CTRunGetAdvances(run, CFRange(location: 0, length: 1), &advance)
        
        // Get glyph bounds
        var bounds = CTFontGetBoundingRectsForGlyphs(
            font, .default, &glyph, nil, 1
        )
        
        // Add padding
        let padding: CGFloat = 2
        let width = Int(ceil(bounds.width) + padding * 2)
        let height = Int(ceil(bounds.height) + padding * 2)
        
        guard width > 0 && height > 0 else {
            // Space or empty glyph
            return GlyphInfo(
                textureRect: .zero,
                size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                bearing: CGPoint(x: bounds.origin.x, y: bounds.origin.y),
                advance: advance.width
            )
        }
        
        // Check if we need to wrap to next row
        if packX + width > atlasWidth {
            packX = 0
            packY += rowHeight
            rowHeight = 0
        }
        
        // Check if we need to expand atlas
        if packY + height > atlasHeight {
            // Atlas full - for now just return nil
            // TODO: Resize atlas or use multiple atlases
            return nil
        }
        
        // Render glyph to bitmap
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        context.setFillColor(gray: 1, alpha: 1)
        context.textMatrix = .identity
        
        // Position glyph
        let x = padding - bounds.origin.x
        let y = padding - bounds.origin.y
        
        var position = CGPoint(x: x, y: y)
        CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        
        // Copy to texture
        guard let data = context.data else { return nil }
        
        let region = MTLRegion(
            origin: MTLOrigin(x: packX, y: packY, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        texture?.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: width
        )
        
        // Calculate UV rect
        let textureRect = CGRect(
            x: CGFloat(packX) / CGFloat(atlasWidth),
            y: CGFloat(packY) / CGFloat(atlasHeight),
            width: CGFloat(width) / CGFloat(atlasWidth),
            height: CGFloat(height) / CGFloat(atlasHeight)
        )
        
        let info = GlyphInfo(
            textureRect: textureRect,
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            bearing: CGPoint(x: bounds.origin.x - padding, y: bounds.origin.y - padding),
            advance: advance.width
        )
        
        // Update packing position
        packX += width
        rowHeight = max(rowHeight, height)
        
        return info
    }
    
    private static func measureGlyph(_ char: Character, font: CTFont) -> (size: CGSize, advance: CGFloat) {
        let string = String(char) as CFString
        let attrString = CFAttributedStringCreate(
            nil,
            string,
            [kCTFontAttributeName: font] as CFDictionary
        )!
        
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        
        guard let run = runs.first else {
            return (CGSize.zero, 0)
        }
        
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        
        var advance = CGSize()
        CTRunGetAdvances(run, CFRange(location: 0, length: 1), &advance)
        
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        
        return (bounds.size, advance.width)
    }
}
