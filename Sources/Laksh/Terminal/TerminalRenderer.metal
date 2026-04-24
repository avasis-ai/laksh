#include <metal_stdlib>
using namespace metal;

// Vertex shader input
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 foreground [[attribute(2)]];
    float4 background [[attribute(3)]];
    uint flags [[attribute(4)]];
};

// Fragment shader input
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 foreground;
    float4 background;
    uint flags;
};

// Uniforms
struct Uniforms {
    float2 viewportSize;
    float2 cellSize;
    float time;
};

// Flags for cell rendering
constant uint FLAG_HAS_GLYPH = 1 << 0;
constant uint FLAG_BOLD = 1 << 1;
constant uint FLAG_ITALIC = 1 << 2;
constant uint FLAG_UNDERLINE = 1 << 3;
constant uint FLAG_STRIKETHROUGH = 1 << 4;
constant uint FLAG_INVERSE = 1 << 5;
constant uint FLAG_CURSOR = 1 << 6;
constant uint FLAG_CURSOR_BLINK = 1 << 7;

// Vertex shader for cell quads
vertex VertexOut cellVertex(
    VertexIn in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]]
) {
    VertexOut out;
    
    // Convert from pixel coords to NDC
    float2 ndc = (in.position / uniforms.viewportSize) * 2.0 - 1.0;
    ndc.y = -ndc.y; // Flip Y
    
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.foreground = in.foreground;
    out.background = in.background;
    out.flags = in.flags;
    
    return out;
}

// Fragment shader for cell rendering
fragment float4 cellFragment(
    VertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]],
    texture2d<float> glyphAtlas [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float4 fg = in.foreground;
    float4 bg = in.background;
    
    // Handle inverse
    if ((in.flags & FLAG_INVERSE) != 0) {
        float4 temp = fg;
        fg = bg;
        bg = temp;
    }
    
    // Start with background
    float4 color = bg;
    
    // Sample glyph if present
    if ((in.flags & FLAG_HAS_GLYPH) != 0) {
        float4 glyph = glyphAtlas.sample(glyphSampler, in.texCoord);
        // Use alpha for text blending
        color = mix(bg, fg, glyph.a);
    }
    
    // Draw underline
    if ((in.flags & FLAG_UNDERLINE) != 0) {
        float lineY = 0.9;
        if (in.texCoord.y > lineY && in.texCoord.y < lineY + 0.1) {
            color = fg;
        }
    }
    
    // Draw strikethrough
    if ((in.flags & FLAG_STRIKETHROUGH) != 0) {
        float lineY = 0.5;
        if (in.texCoord.y > lineY - 0.05 && in.texCoord.y < lineY + 0.05) {
            color = fg;
        }
    }
    
    // Cursor rendering
    if ((in.flags & FLAG_CURSOR) != 0) {
        bool blink = (in.flags & FLAG_CURSOR_BLINK) != 0;
        bool visible = !blink || (fmod(uniforms.time, 1.0) < 0.5);
        
        if (visible) {
            // Block cursor - invert colors
            color = mix(color, float4(1.0) - color, 0.8);
        }
    }
    
    return color;
}

// Simple vertex shader for fullscreen quad (for post-processing if needed)
vertex VertexOut fullscreenVertex(
    uint vertexID [[vertex_id]],
    constant Uniforms& uniforms [[buffer(0)]]
) {
    VertexOut out;
    
    // Generate fullscreen triangle
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    
    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    out.foreground = float4(1.0);
    out.background = float4(0.0, 0.0, 0.0, 1.0);
    out.flags = 0;
    
    return out;
}
