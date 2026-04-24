import Foundation
import Metal
import MetalKit
import simd

/// Metal-based terminal renderer inspired by Ghostty
/// Renders terminal grid to a MTKView with GPU acceleration
final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    
    private let fontAtlas: FontAtlas
    private var vertexBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    
    private var buffer: TerminalBuffer
    private var viewportSize: SIMD2<Float> = .zero
    
    private var startTime: CFAbsoluteTime
    
    // Color palette (xterm 256 colors subset)
    private let colorPalette: [SIMD4<Float>] = {
        var colors: [SIMD4<Float>] = []
        
        // Standard 16 colors
        let standard: [(Float, Float, Float)] = [
            (0.0, 0.0, 0.0),       // 0: Black
            (0.8, 0.0, 0.0),       // 1: Red
            (0.0, 0.8, 0.0),       // 2: Green
            (0.8, 0.8, 0.0),       // 3: Yellow
            (0.0, 0.0, 0.8),       // 4: Blue
            (0.8, 0.0, 0.8),       // 5: Magenta
            (0.0, 0.8, 0.8),       // 6: Cyan
            (0.75, 0.75, 0.75),    // 7: White
            (0.5, 0.5, 0.5),       // 8: Bright Black
            (1.0, 0.0, 0.0),       // 9: Bright Red
            (0.0, 1.0, 0.0),       // 10: Bright Green
            (1.0, 1.0, 0.0),       // 11: Bright Yellow
            (0.0, 0.0, 1.0),       // 12: Bright Blue
            (1.0, 0.0, 1.0),       // 13: Bright Magenta
            (0.0, 1.0, 1.0),       // 14: Bright Cyan
            (1.0, 1.0, 1.0),       // 15: Bright White
        ]
        
        for (r, g, b) in standard {
            colors.append(SIMD4<Float>(r, g, b, 1.0))
        }
        
        // 216 color cube (6x6x6)
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    let rf = r == 0 ? 0.0 : Float(r * 40 + 55) / 255.0
                    let gf = g == 0 ? 0.0 : Float(g * 40 + 55) / 255.0
                    let bf = b == 0 ? 0.0 : Float(b * 40 + 55) / 255.0
                    colors.append(SIMD4<Float>(rf, gf, bf, 1.0))
                }
            }
        }
        
        // 24 grayscale
        for i in 0..<24 {
            let v = Float(i * 10 + 8) / 255.0
            colors.append(SIMD4<Float>(v, v, v, 1.0))
        }
        
        return colors
    }()
    
    // Default colors
    private let defaultForeground = SIMD4<Float>(0.93, 0.91, 0.87, 1.0)  // #EDE8DF
    private let defaultBackground = SIMD4<Float>(0.031, 0.031, 0.031, 1.0)  // #080808
    
    struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
        var foreground: SIMD4<Float>
        var background: SIMD4<Float>
        var flags: UInt32
    }
    
    struct Uniforms {
        var viewportSize: SIMD2<Float>
        var cellSize: SIMD2<Float>
        var time: Float
        var padding: Float = 0
    }
    
    private let FLAG_HAS_GLYPH: UInt32 = 1 << 0
    private let FLAG_BOLD: UInt32 = 1 << 1
    private let FLAG_ITALIC: UInt32 = 1 << 2
    private let FLAG_UNDERLINE: UInt32 = 1 << 3
    private let FLAG_STRIKETHROUGH: UInt32 = 1 << 4
    private let FLAG_INVERSE: UInt32 = 1 << 5
    private let FLAG_CURSOR: UInt32 = 1 << 6
    private let FLAG_CURSOR_BLINK: UInt32 = 1 << 7
    
    init?(device: MTLDevice, buffer: TerminalBuffer) {
        guard let queue = device.makeCommandQueue() else { return nil }
        
        self.device = device
        self.commandQueue = queue
        self.buffer = buffer
        self.fontAtlas = FontAtlas(device: device)
        self.startTime = CFAbsoluteTimeGetCurrent()
        
        super.init()
        
        setupPipeline()
        setupSampler()
    }
    
    private func setupPipeline() {
        // Load shader library
        guard let library = try? device.makeDefaultLibrary() else {
            // Fall back to loading from source
            guard let shaderPath = Bundle.main.path(forResource: "TerminalRenderer", ofType: "metal"),
                  let shaderSource = try? String(contentsOfFile: shaderPath),
                  let library = try? device.makeLibrary(source: shaderSource, options: nil)
            else {
                print("Failed to load terminal shaders")
                return
            }
            setupPipelineWithLibrary(library)
            return
        }
        setupPipelineWithLibrary(library)
    }
    
    private func setupPipelineWithLibrary(_ library: MTLLibrary) {
        let vertexFunction = library.makeFunction(name: "cellVertex")
        let fragmentFunction = library.makeFunction(name: "cellFragment")
        
        let vertexDescriptor = MTLVertexDescriptor()
        
        // Position
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 1
        
        // TexCoord
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 1
        
        // Foreground
        vertexDescriptor.attributes[2].format = .float4
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD2<Float>>.stride * 2
        vertexDescriptor.attributes[2].bufferIndex = 1
        
        // Background
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD2<Float>>.stride * 2 + MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.attributes[3].bufferIndex = 1
        
        // Flags
        vertexDescriptor.attributes[4].format = .uint
        vertexDescriptor.attributes[4].offset = MemoryLayout<SIMD2<Float>>.stride * 2 + MemoryLayout<SIMD4<Float>>.stride * 2
        vertexDescriptor.attributes[4].bufferIndex = 1
        
        vertexDescriptor.layouts[1].stride = MemoryLayout<Vertex>.stride
        vertexDescriptor.layouts[1].stepRate = 1
        vertexDescriptor.layouts[1].stepFunction = .perVertex
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Enable alpha blending
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state: \(error)")
        }
    }
    
    private func setupSampler() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        
        samplerState = device.makeSamplerState(descriptor: descriptor)
    }
    
    func updateBuffer(_ buffer: TerminalBuffer) {
        self.buffer = buffer
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
    }
    
    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        
        // Clear to background color
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(defaultBackground.x),
            green: Double(defaultBackground.y),
            blue: Double(defaultBackground.z),
            alpha: 1.0
        )
        
        // Build vertex data
        let vertices = buildVertices()
        
        guard !vertices.isEmpty else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        
        // Create/update vertex buffer
        let vertexData = vertices.withUnsafeBytes { Data($0) }
        if vertexBuffer == nil || vertexBuffer!.length < vertexData.count {
            vertexBuffer = device.makeBuffer(length: max(vertexData.count, 1024 * 1024), options: .storageModeManaged)
        }
        
        vertexData.withUnsafeBytes { ptr in
            memcpy(vertexBuffer!.contents(), ptr.baseAddress!, vertexData.count)
        }
        vertexBuffer?.didModifyRange(0..<vertexData.count)
        
        // Update uniforms
        var uniforms = Uniforms(
            viewportSize: viewportSize,
            cellSize: SIMD2<Float>(Float(fontAtlas.cellWidth), Float(fontAtlas.cellHeight)),
            time: Float(CFAbsoluteTimeGetCurrent() - startTime)
        )
        
        if uniformBuffer == nil {
            uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeManaged)
        }
        memcpy(uniformBuffer!.contents(), &uniforms, MemoryLayout<Uniforms>.stride)
        uniformBuffer?.didModifyRange(0..<MemoryLayout<Uniforms>.stride)
        
        // Render
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        
        if let texture = fontAtlas.texture {
            encoder.setFragmentTexture(texture, index: 0)
        }
        if let sampler = samplerState {
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func buildVertices() -> [Vertex] {
        var vertices: [Vertex] = []
        vertices.reserveCapacity(buffer.rows * buffer.cols * 6)
        
        let cellW = Float(fontAtlas.cellWidth)
        let cellH = Float(fontAtlas.cellHeight)
        
        for row in 0..<buffer.rows {
            for col in 0..<buffer.cols {
                let cell = buffer.cell(at: row, col: col)
                
                let x = Float(col) * cellW
                let y = Float(row) * cellH
                
                // Convert colors
                let fg = colorFromCell(cell.foreground, default: defaultForeground)
                let bg = colorFromCell(cell.background, default: defaultBackground)
                
                // Build flags
                var flags: UInt32 = 0
                if cell.character != " " {
                    flags |= FLAG_HAS_GLYPH
                }
                if cell.attributes.contains(.bold) { flags |= FLAG_BOLD }
                if cell.attributes.contains(.italic) { flags |= FLAG_ITALIC }
                if cell.attributes.contains(.underline) { flags |= FLAG_UNDERLINE }
                if cell.attributes.contains(.strikethrough) { flags |= FLAG_STRIKETHROUGH }
                if cell.attributes.contains(.inverse) { flags |= FLAG_INVERSE }
                
                // Cursor
                if row == buffer.cursor.row && col == buffer.cursor.col && buffer.cursor.visible {
                    flags |= FLAG_CURSOR
                    flags |= FLAG_CURSOR_BLINK
                }
                
                // Get glyph UV coords
                var uvRect = CGRect.zero
                if cell.character != " " {
                    if let glyph = fontAtlas.glyph(
                        for: cell.character,
                        bold: cell.attributes.contains(.bold),
                        italic: cell.attributes.contains(.italic)
                    ) {
                        uvRect = glyph.textureRect
                    }
                }
                
                // Generate quad (2 triangles, 6 vertices)
                let positions: [SIMD2<Float>] = [
                    SIMD2(x, y),
                    SIMD2(x + cellW, y),
                    SIMD2(x + cellW, y + cellH),
                    SIMD2(x, y),
                    SIMD2(x + cellW, y + cellH),
                    SIMD2(x, y + cellH),
                ]
                
                let u0 = Float(uvRect.minX)
                let v0 = Float(uvRect.minY)
                let u1 = Float(uvRect.maxX)
                let v1 = Float(uvRect.maxY)
                
                let texCoords: [SIMD2<Float>] = [
                    SIMD2(u0, v0),
                    SIMD2(u1, v0),
                    SIMD2(u1, v1),
                    SIMD2(u0, v0),
                    SIMD2(u1, v1),
                    SIMD2(u0, v1),
                ]
                
                for i in 0..<6 {
                    vertices.append(Vertex(
                        position: positions[i],
                        texCoord: texCoords[i],
                        foreground: fg,
                        background: bg,
                        flags: flags
                    ))
                }
            }
        }
        
        return vertices
    }
    
    private func colorFromCell(_ color: TerminalBuffer.Cell.Color, default defaultColor: SIMD4<Float>) -> SIMD4<Float> {
        switch color {
        case .default:
            return defaultColor
        case .indexed(let idx):
            if idx < colorPalette.count {
                return colorPalette[Int(idx)]
            }
            return defaultColor
        case .rgb(let r, let g, let b):
            return SIMD4<Float>(Float(r) / 255.0, Float(g) / 255.0, Float(b) / 255.0, 1.0)
        }
    }
}
