using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using BfresLibrary;
using BfresLibrary.Helpers;
using BfresLibrary.Swizzling;
using SharpGLTF.Geometry;
using SharpGLTF.Geometry.VertexTypes;
using SharpGLTF.Materials;
using SharpGLTF.Memory;
using SharpGLTF.Scenes;
using Syroot.NintenTools.NSW.Bntx;
using Syroot.NintenTools.NSW.Bntx.GFX;
using BntxTexture = Syroot.NintenTools.NSW.Bntx.Texture;
using Vector2 = System.Numerics.Vector2;
using Vector3 = System.Numerics.Vector3;
using Vector4 = System.Numerics.Vector4;
using Matrix4x4 = System.Numerics.Matrix4x4;
using Vector4F = Syroot.Maths.Vector4F;

namespace BfresToGltf;

/// <summary>
/// CLI tool that converts BFRES model files (optionally inside SZS/SARC archives)
/// to GLTF Binary (.glb) format with per-model output and texture support.
///
/// Each FMDL model inside a BFRES is exported as a separate .glb file named
/// after the model name (corresponding to fmdb_name in ActorDb).
///
/// Textures are extracted from embedded BNTX, deswizzled, BCn-decompressed
/// to RGBA, and embedded as PNG in the GLTF material.
///
/// Usage:
///   BfresToGltf &lt;input_path&gt; &lt;output_dir&gt; [--batch]
/// </summary>
class Program
{
    static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: BfresToGltf <input_path> <output_dir> [--batch]");
            Console.Error.WriteLine("  input_path: .bfres/.szs file or directory (with --batch)");
            Console.Error.WriteLine("  output_dir: directory to write .glb files");
            return 1;
        }

        string inputPath = args[0];
        string outputDir = args[1];
        bool batch = args.Any(a => a == "--batch");

        Directory.CreateDirectory(outputDir);

        if (batch)
        {
            if (!Directory.Exists(inputPath))
            {
                Console.Error.WriteLine($"Input directory not found: {inputPath}");
                return 1;
            }

            var files = Directory.GetFiles(inputPath)
                .Where(f => f.EndsWith(".szs", StringComparison.OrdinalIgnoreCase)
                         || f.EndsWith(".bfres", StringComparison.OrdinalIgnoreCase))
                .ToArray();

            Console.WriteLine($"Found {files.Length} model files to convert.");
            int success = 0, failed = 0;

            foreach (var file in files)
            {
                try
                {
                    int count = ConvertFile(file, outputDir);
                    success += count;
                    Console.WriteLine($"  OK {Path.GetFileName(file)} ({count} models)");
                }
                catch (Exception ex)
                {
                    failed++;
                    Console.Error.WriteLine($"  FAIL {Path.GetFileName(file)}: {ex.Message}");
                }
            }

            Console.WriteLine($"Done: {success} models converted, {failed} files failed.");
            return failed > 0 ? 2 : 0;
        }
        else
        {
            if (!File.Exists(inputPath))
            {
                Console.Error.WriteLine($"Input file not found: {inputPath}");
                return 1;
            }

            try
            {
                int count = ConvertFile(inputPath, outputDir);
                Console.WriteLine($"Converted {count} models from: {Path.GetFileName(inputPath)}");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error: {ex.Message}");
                return 1;
            }
        }
    }

    /// <summary>
    /// Convert a single BFRES/SZS file. Outputs one .glb per FMDL model.
    /// Returns the number of models exported.
    /// </summary>
    static int ConvertFile(string inputPath, string outputDir)
    {
        byte[] data = File.ReadAllBytes(inputPath);

        // Yaz0 decompression
        if (data.Length >= 4 && data[0] == 'Y' && data[1] == 'a' && data[2] == 'z' && data[3] == '0')
            data = Yaz0Decompress(data);

        // SARC extraction — get BFRES + BNTX
        byte[]? bntxData = null;
        if (data.Length >= 4 && data[0] == 'S' && data[1] == 'A' && data[2] == 'R' && data[3] == 'C')
        {
            var sarcFiles = ExtractFromSarc(data);
            data = sarcFiles.FirstOrDefault(f => f.name.EndsWith(".bfres", StringComparison.OrdinalIgnoreCase)).data
                ?? throw new Exception("No BFRES file found in SARC archive.");
            bntxData = sarcFiles.FirstOrDefault(f => f.name.EndsWith(".bntx", StringComparison.OrdinalIgnoreCase)).data;
        }

        // Parse BFRES
        using var stream = new MemoryStream(data);
        var resFile = new ResFile(stream);

        // Extract BNTX textures — BfresLibrary's Switch loader already parses
        // embedded .bntx files into LoadedFileData (and empties raw Data to save memory).
        Dictionary<string, DecodedTexture> textureCache = new();
        BntxFile? bntx = null;

        foreach (var extFile in resFile.ExternalFiles)
        {
            if (extFile.Key.EndsWith(".bntx", StringComparison.OrdinalIgnoreCase))
            {
                // BfresLibrary already parsed this into LoadedFileData
                if (extFile.Value.LoadedFileData is BntxFile loadedBntx)
                {
                    bntx = loadedBntx;
                }
                else if (extFile.Value.Data?.Length > 0)
                {
                    // Fallback: try parsing raw data if LoadedFileData wasn't set
                    try { bntx = new BntxFile(new MemoryStream(extFile.Value.Data)); }
                    catch (Exception ex) { Console.Error.WriteLine($"    Warning: Failed to parse BNTX: {ex.Message}"); }
                }
                break;
            }
        }

        // Try standalone BNTX from SARC if not found in BFRES
        if (bntx == null && bntxData != null)
        {
            try { bntx = new BntxFile(new MemoryStream(bntxData)); }
            catch (Exception ex) { Console.Error.WriteLine($"    Warning: Failed to parse SARC BNTX: {ex.Message}"); }
        }

        // Pre-decode all textures
        if (bntx != null)
        {
            foreach (var tex in bntx.Textures)
            {
                try
                {
                    var decoded = DecodeTexture(tex);
                    if (decoded != null)
                        textureCache[tex.Name] = decoded;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"    Warning: Failed to decode texture '{tex.Name}': {ex.Message}");
                }
            }
            if (textureCache.Count > 0)
                Console.WriteLine($"    Decoded {textureCache.Count}/{bntx.Textures.Count} textures");
        }

        // Export one GLB per FMDL model
        int exported = 0;
        foreach (var model in resFile.Models.Values)
        {
            try
            {
                var scene = new SceneBuilder();
                ConvertModel(model, scene, textureCache);

                var gltfModel = scene.ToGltf2();
                string outputPath = Path.Combine(outputDir, model.Name + ".glb");
                gltfModel.SaveGLB(outputPath);
                exported++;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"    Warning: Could not convert model '{model.Name}': {ex.Message}");
            }
        }

        return exported;
    }

    static void ConvertModel(Model model, SceneBuilder scene, Dictionary<string, DecodedTexture> textureCache)
    {
        foreach (var shape in model.Shapes.Values)
        {
            try
            {
                ConvertShape(shape, model, scene, textureCache);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"      Warning: Could not convert shape '{shape.Name}': {ex.Message}");
            }
        }
    }

    static void ConvertShape(Shape shape, Model model, SceneBuilder scene, Dictionary<string, DecodedTexture> textureCache)
    {
        // Material setup
        MaterialBuilder matBuilder;
        bool hasTexture = false;

        if (shape.MaterialIndex >= 0 && shape.MaterialIndex < model.Materials.Count)
        {
            var mat = model.Materials[shape.MaterialIndex];
            matBuilder = new MaterialBuilder(mat.Name);

            // Try to find the albedo/diffuse texture
            DecodedTexture? albedoTex = null;
            foreach (var texRef in mat.TextureRefs)
            {
                // Common Splatoon 2 texture naming: _Alb (albedo/diffuse)
                if (textureCache.TryGetValue(texRef.Name, out var decoded))
                {
                    // Use the first texture we find, prefer _Alb suffix
                    if (albedoTex == null || texRef.Name.Contains("_Alb", StringComparison.OrdinalIgnoreCase))
                        albedoTex = decoded;
                }
            }

            if (albedoTex != null)
            {
                hasTexture = true;
                var imageBuilder = ImageBuilder.From(albedoTex.PngData, "albedo");
                matBuilder.WithMetallicRoughnessShader()
                    .WithBaseColor(imageBuilder)
                    .WithMetallicRoughness(0.0f, 1.0f);
            }
            else
            {
                // Grey fallback — won't interfere when texture is present
                matBuilder.WithMetallicRoughnessShader()
                    .WithChannelParam(KnownChannel.BaseColor, KnownProperty.RGBA, new Vector4(0.6f, 0.6f, 0.6f, 1.0f))
                    .WithMetallicRoughness(0.0f, 1.0f);
            }
        }
        else
        {
            matBuilder = new MaterialBuilder("default")
                .WithMetallicRoughnessShader()
                .WithChannelParam(KnownChannel.BaseColor, KnownProperty.RGBA, new Vector4(0.6f, 0.6f, 0.6f, 1.0f))
                .WithMetallicRoughness(0.0f, 1.0f);
        }

        // Vertex data extraction
        var vertexBuffer = model.VertexBuffers[shape.VertexBufferIndex];
        var helper = new VertexBufferHelper(vertexBuffer, Syroot.BinaryData.ByteOrder.LittleEndian);

        Vector4F[]? positions = null;
        Vector4F[]? normals = null;
        Vector4F[]? texcoords = null;

        foreach (var attr in helper.Attributes)
        {
            if (attr.Name == "_p0") positions = attr.Data;
            else if (attr.Name == "_n0") normals = attr.Data;
            else if (attr.Name == "_u0") texcoords = attr.Data;
        }

        if (positions == null)
        {
            Console.Error.WriteLine($"      Warning: No position data for shape '{shape.Name}'");
            return;
        }

        // Build mesh with or without UVs
        if (hasTexture && texcoords != null)
        {
            var meshBuilder = new MeshBuilder<VertexPositionNormal, VertexTexture1, VertexEmpty>(shape.Name);
            var prim = meshBuilder.UsePrimitive(matBuilder);

            foreach (var mesh in shape.Meshes)
            {
                var indices = mesh.GetIndices().ToArray();
                for (int i = 0; i + 2 < indices.Length; i += 3)
                {
                    int i0 = (int)indices[i], i1 = (int)indices[i + 1], i2 = (int)indices[i + 2];
                    if (i0 >= positions.Length || i1 >= positions.Length || i2 >= positions.Length) continue;

                    // Original winding preserved: negating X+Z is a 180° Y rotation (no handedness change)
                    prim.AddTriangle(
                        (MakeVertex(positions, normals, i0), MakeUV(texcoords, i0)),
                        (MakeVertex(positions, normals, i1), MakeUV(texcoords, i1)),
                        (MakeVertex(positions, normals, i2), MakeUV(texcoords, i2)));
                }
                break; // First LOD only
            }
            scene.AddRigidMesh(meshBuilder, Matrix4x4.Identity);
        }
        else
        {
            var meshBuilder = new MeshBuilder<VertexPositionNormal, VertexEmpty, VertexEmpty>(shape.Name);
            var prim = meshBuilder.UsePrimitive(matBuilder);

            foreach (var mesh in shape.Meshes)
            {
                var indices = mesh.GetIndices().ToArray();
                for (int i = 0; i + 2 < indices.Length; i += 3)
                {
                    int i0 = (int)indices[i], i1 = (int)indices[i + 1], i2 = (int)indices[i + 2];
                    if (i0 >= positions.Length || i1 >= positions.Length || i2 >= positions.Length) continue;

                    // Original winding preserved: negating X+Z is a 180° Y rotation (no handedness change)
                    prim.AddTriangle(
                        MakeVertex(positions, normals, i0),
                        MakeVertex(positions, normals, i1),
                        MakeVertex(positions, normals, i2));
                }
                break; // First LOD only
            }
            scene.AddRigidMesh(meshBuilder, Matrix4x4.Identity);
        }
    }

    static VertexPositionNormal MakeVertex(Vector4F[] positions, Vector4F[]? normals, int index)
    {
        var pos = positions[index];
        // Negate X and Z: BFRES uses (X-left, Y-up, Z-forward), GLTF uses (X-right, Y-up, Z-toward-viewer)
        // This is a 180° rotation around Y (preserves handedness, no winding swap needed)
        var position = new Vector3(-pos.X, pos.Y, -pos.Z);

        Vector3 normal;
        if (normals != null && index < normals.Length)
        {
            var n = normals[index];
            normal = Vector3.Normalize(new Vector3(-n.X, n.Y, -n.Z));
            if (float.IsNaN(normal.X)) normal = Vector3.UnitY;
        }
        else
        {
            normal = Vector3.UnitY;
        }

        return new VertexPositionNormal(position, normal);
    }

    static VertexTexture1 MakeUV(Vector4F[] texcoords, int index)
    {
        if (index < texcoords.Length)
        {
            var uv = texcoords[index];
            return new VertexTexture1(new Vector2(uv.X, uv.Y));
        }
        return new VertexTexture1(Vector2.Zero);
    }

    // =====================================================================
    // Texture Decoding Pipeline: BNTX → Deswizzle → BCn Decompress → PNG
    // =====================================================================

    record DecodedTexture(byte[] PngData, int Width, int Height);

    static DecodedTexture? DecodeTexture(BntxTexture tex)
    {
        if (tex.TextureData == null || tex.TextureData.Count == 0 || tex.TextureData[0].Count == 0)
            return null;

        // Deswizzle mip level 0, array level 0
        byte[] rawData = tex.TextureData[0][0];
        byte[] deswizzled = TegraX1Swizzle.GetImageData(tex, rawData, 0, 0, 0);

        if (deswizzled.Length == 0)
            return null;

        // Decompress BCn to RGBA8
        byte[]? rgba = DecompressBCn(deswizzled, (int)tex.Width, (int)tex.Height, tex.Format);
        if (rgba == null)
            return null;

        // Encode to PNG
        byte[] png = EncodePng(rgba, (int)tex.Width, (int)tex.Height);
        return new DecodedTexture(png, (int)tex.Width, (int)tex.Height);
    }

    static byte[]? DecompressBCn(byte[] data, int width, int height, SurfaceFormat format)
    {
        int blockW = (width + 3) / 4;
        int blockH = (height + 3) / 4;

        return format switch
        {
            SurfaceFormat.BC1_UNORM or SurfaceFormat.BC1_SRGB => DecompressBC1(data, width, height, blockW, blockH),
            SurfaceFormat.BC2_UNORM or SurfaceFormat.BC2_SRGB => DecompressBC2(data, width, height, blockW, blockH),
            SurfaceFormat.BC3_UNORM or SurfaceFormat.BC3_SRGB => DecompressBC3(data, width, height, blockW, blockH),
            SurfaceFormat.BC4_UNORM or SurfaceFormat.BC4_SNORM => DecompressBC4(data, width, height, blockW, blockH),
            SurfaceFormat.BC5_UNORM or SurfaceFormat.BC5_SNORM => DecompressBC5(data, width, height, blockW, blockH),
            SurfaceFormat.R8_G8_B8_A8_UNORM or SurfaceFormat.R8_G8_B8_A8_SRGB or SurfaceFormat.R8_G8_B8_A8_SNORM => data, // Already RGBA
            _ => null // Unsupported format (ASTC, etc.)
        };
    }

    // ---- BC1 (DXT1) ----
    static byte[] DecompressBC1(byte[] data, int w, int h, int bw, int bh)
    {
        byte[] output = new byte[w * h * 4];
        int offset = 0;
        for (int by = 0; by < bh; by++)
        {
            for (int bx = 0; bx < bw; bx++)
            {
                if (offset + 8 > data.Length) break;
                DecodeBC1Block(data, offset, output, bx * 4, by * 4, w, h);
                offset += 8;
            }
        }
        return output;
    }

    static void DecodeBC1Block(byte[] data, int offset, byte[] output, int px, int py, int w, int h)
    {
        ushort c0 = (ushort)(data[offset] | (data[offset + 1] << 8));
        ushort c1 = (ushort)(data[offset + 2] | (data[offset + 3] << 8));
        uint bits = (uint)(data[offset + 4] | (data[offset + 5] << 8) | (data[offset + 6] << 16) | (data[offset + 7] << 24));

        var colors = new byte[4][];
        colors[0] = RGB565ToRGBA(c0);
        colors[1] = RGB565ToRGBA(c1);

        if (c0 > c1)
        {
            colors[2] = new byte[] { (byte)((2 * colors[0][0] + colors[1][0] + 1) / 3), (byte)((2 * colors[0][1] + colors[1][1] + 1) / 3), (byte)((2 * colors[0][2] + colors[1][2] + 1) / 3), 255 };
            colors[3] = new byte[] { (byte)((colors[0][0] + 2 * colors[1][0] + 1) / 3), (byte)((colors[0][1] + 2 * colors[1][1] + 1) / 3), (byte)((colors[0][2] + 2 * colors[1][2] + 1) / 3), 255 };
        }
        else
        {
            colors[2] = new byte[] { (byte)((colors[0][0] + colors[1][0]) / 2), (byte)((colors[0][1] + colors[1][1]) / 2), (byte)((colors[0][2] + colors[1][2]) / 2), 255 };
            colors[3] = new byte[] { 0, 0, 0, 0 }; // Transparent
        }

        for (int y = 0; y < 4; y++)
        {
            for (int x = 0; x < 4; x++)
            {
                int fx = px + x, fy = py + y;
                if (fx >= w || fy >= h) continue;
                int idx = (int)((bits >> (2 * (y * 4 + x))) & 3);
                int outPos = (fy * w + fx) * 4;
                output[outPos] = colors[idx][0];
                output[outPos + 1] = colors[idx][1];
                output[outPos + 2] = colors[idx][2];
                output[outPos + 3] = colors[idx][3];
            }
        }
    }

    // ---- BC2 (DXT3) — explicit alpha ----
    static byte[] DecompressBC2(byte[] data, int w, int h, int bw, int bh)
    {
        byte[] output = new byte[w * h * 4];
        int offset = 0;
        for (int by = 0; by < bh; by++)
        {
            for (int bx = 0; bx < bw; bx++)
            {
                if (offset + 16 > data.Length) break;
                // First 8 bytes: explicit alpha, next 8: BC1 color
                DecodeBC1Block(data, offset + 8, output, bx * 4, by * 4, w, h);
                // Apply explicit 4-bit alpha
                for (int y = 0; y < 4; y++)
                {
                    int alphaWord = data[offset + y * 2] | (data[offset + y * 2 + 1] << 8);
                    for (int x = 0; x < 4; x++)
                    {
                        int fx = bx * 4 + x, fy = by * 4 + y;
                        if (fx >= w || fy >= h) continue;
                        int a4 = (alphaWord >> (x * 4)) & 0xF;
                        output[(fy * w + fx) * 4 + 3] = (byte)(a4 | (a4 << 4));
                    }
                }
                offset += 16;
            }
        }
        return output;
    }

    // ---- BC3 (DXT5) — interpolated alpha ----
    static byte[] DecompressBC3(byte[] data, int w, int h, int bw, int bh)
    {
        byte[] output = new byte[w * h * 4];
        int offset = 0;
        for (int by = 0; by < bh; by++)
        {
            for (int bx = 0; bx < bw; bx++)
            {
                if (offset + 16 > data.Length) break;
                // First 8 bytes: interpolated alpha block
                byte a0 = data[offset], a1 = data[offset + 1];
                ulong alphaBits = 0;
                for (int i = 2; i < 8; i++)
                    alphaBits |= (ulong)data[offset + i] << (8 * (i - 2));

                byte[] alphas = InterpolateAlpha(a0, a1);

                // Next 8 bytes: BC1 color
                DecodeBC1Block(data, offset + 8, output, bx * 4, by * 4, w, h);

                // Apply interpolated alpha
                for (int y = 0; y < 4; y++)
                {
                    for (int x = 0; x < 4; x++)
                    {
                        int fx = bx * 4 + x, fy = by * 4 + y;
                        if (fx >= w || fy >= h) continue;
                        int alphaIdx = (int)((alphaBits >> (3 * (y * 4 + x))) & 7);
                        output[(fy * w + fx) * 4 + 3] = alphas[alphaIdx];
                    }
                }
                offset += 16;
            }
        }
        return output;
    }

    // ---- BC4 (single-channel, red) ----
    static byte[] DecompressBC4(byte[] data, int w, int h, int bw, int bh)
    {
        byte[] output = new byte[w * h * 4];
        int offset = 0;
        for (int by = 0; by < bh; by++)
        {
            for (int bx = 0; bx < bw; bx++)
            {
                if (offset + 8 > data.Length) break;
                byte r0 = data[offset], r1 = data[offset + 1];
                ulong bits = 0;
                for (int i = 2; i < 8; i++)
                    bits |= (ulong)data[offset + i] << (8 * (i - 2));
                byte[] reds = InterpolateAlpha(r0, r1);

                for (int y = 0; y < 4; y++)
                {
                    for (int x = 0; x < 4; x++)
                    {
                        int fx = bx * 4 + x, fy = by * 4 + y;
                        if (fx >= w || fy >= h) continue;
                        int idx = (int)((bits >> (3 * (y * 4 + x))) & 7);
                        int outPos = (fy * w + fx) * 4;
                        output[outPos] = reds[idx];
                        output[outPos + 1] = reds[idx];
                        output[outPos + 2] = reds[idx];
                        output[outPos + 3] = 255;
                    }
                }
                offset += 8;
            }
        }
        return output;
    }

    // ---- BC5 (two-channel, red+green → normal map) ----
    static byte[] DecompressBC5(byte[] data, int w, int h, int bw, int bh)
    {
        byte[] output = new byte[w * h * 4];
        int offset = 0;
        for (int by = 0; by < bh; by++)
        {
            for (int bx = 0; bx < bw; bx++)
            {
                if (offset + 16 > data.Length) break;
                // Red channel
                byte r0 = data[offset], r1 = data[offset + 1];
                ulong rBits = 0;
                for (int i = 2; i < 8; i++) rBits |= (ulong)data[offset + i] << (8 * (i - 2));
                byte[] reds = InterpolateAlpha(r0, r1);
                // Green channel
                byte g0 = data[offset + 8], g1 = data[offset + 9];
                ulong gBits = 0;
                for (int i = 2; i < 8; i++) gBits |= (ulong)data[offset + 8 + i] << (8 * (i - 2));
                byte[] greens = InterpolateAlpha(g0, g1);

                for (int y = 0; y < 4; y++)
                {
                    for (int x = 0; x < 4; x++)
                    {
                        int fx = bx * 4 + x, fy = by * 4 + y;
                        if (fx >= w || fy >= h) continue;
                        int rIdx = (int)((rBits >> (3 * (y * 4 + x))) & 7);
                        int gIdx = (int)((gBits >> (3 * (y * 4 + x))) & 7);
                        int outPos = (fy * w + fx) * 4;
                        output[outPos] = reds[rIdx];
                        output[outPos + 1] = greens[gIdx];
                        output[outPos + 2] = 128; // Blue channel for normal map
                        output[outPos + 3] = 255;
                    }
                }
                offset += 16;
            }
        }
        return output;
    }

    static byte[] InterpolateAlpha(byte a0, byte a1)
    {
        byte[] alphas = new byte[8];
        alphas[0] = a0;
        alphas[1] = a1;
        if (a0 > a1)
        {
            for (int i = 2; i < 8; i++)
                alphas[i] = (byte)(((8 - i) * a0 + (i - 1) * a1 + 3) / 7);
        }
        else
        {
            for (int i = 2; i < 6; i++)
                alphas[i] = (byte)(((6 - i) * a0 + (i - 1) * a1 + 2) / 5);
            alphas[6] = 0;
            alphas[7] = 255;
        }
        return alphas;
    }

    static byte[] RGB565ToRGBA(ushort c)
    {
        int r = (c >> 11) & 0x1F;
        int g = (c >> 5) & 0x3F;
        int b = c & 0x1F;
        return new byte[] { (byte)((r << 3) | (r >> 2)), (byte)((g << 2) | (g >> 4)), (byte)((b << 3) | (b >> 2)), 255 };
    }

    // =====================================================================
    // Minimal PNG Encoder (no external dependencies)
    // =====================================================================

    static byte[] EncodePng(byte[] rgba, int width, int height)
    {
        using var ms = new MemoryStream();
        using var bw = new BinaryWriter(ms);

        // PNG signature
        bw.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });

        // IHDR
        var ihdr = new byte[13];
        WriteBE32(ihdr, 0, (uint)width);
        WriteBE32(ihdr, 4, (uint)height);
        ihdr[8] = 8;  // bit depth
        ihdr[9] = 6;  // RGBA
        ihdr[10] = 0; // compression
        ihdr[11] = 0; // filter
        ihdr[12] = 0; // interlace
        WritePngChunk(bw, "IHDR", ihdr);

        // IDAT — raw image data with filter byte per row, zlib-compressed
        using var idatMs = new MemoryStream();
        // Use DeflateStream wrapped in zlib header
        idatMs.WriteByte(0x78); // zlib CMF
        idatMs.WriteByte(0x01); // zlib FLG (no dict, fastest)
        using (var deflate = new System.IO.Compression.DeflateStream(idatMs, System.IO.Compression.CompressionLevel.Fastest, true))
        {
            for (int y = 0; y < height; y++)
            {
                deflate.WriteByte(0); // Filter: None
                deflate.Write(rgba, y * width * 4, width * 4);
            }
        }
        // Adler32 checksum
        uint adler = Adler32(rgba, width, height);
        idatMs.WriteByte((byte)(adler >> 24));
        idatMs.WriteByte((byte)(adler >> 16));
        idatMs.WriteByte((byte)(adler >> 8));
        idatMs.WriteByte((byte)adler);

        WritePngChunk(bw, "IDAT", idatMs.ToArray());

        // IEND
        WritePngChunk(bw, "IEND", Array.Empty<byte>());

        return ms.ToArray();
    }

    static void WritePngChunk(BinaryWriter bw, string type, byte[] data)
    {
        byte[] typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        WriteBE32(bw, (uint)data.Length);
        bw.Write(typeBytes);
        bw.Write(data);
        // CRC32 over type + data
        uint crc = Crc32(typeBytes, data);
        WriteBE32(bw, crc);
    }

    static void WriteBE32(BinaryWriter bw, uint v)
    {
        bw.Write((byte)(v >> 24)); bw.Write((byte)(v >> 16)); bw.Write((byte)(v >> 8)); bw.Write((byte)v);
    }

    static void WriteBE32(byte[] buf, int offset, uint v)
    {
        buf[offset] = (byte)(v >> 24); buf[offset + 1] = (byte)(v >> 16); buf[offset + 2] = (byte)(v >> 8); buf[offset + 3] = (byte)v;
    }

    static uint Adler32(byte[] rgba, int width, int height)
    {
        uint a = 1, b = 0;
        for (int y = 0; y < height; y++)
        {
            // Filter byte
            a = (a + 0) % 65521; b = (b + a) % 65521;
            for (int x = 0; x < width * 4; x++)
            {
                a = (a + rgba[y * width * 4 + x]) % 65521;
                b = (b + a) % 65521;
            }
        }
        return (b << 16) | a;
    }

    static readonly uint[] CrcTable = MakeCrcTable();
    static uint[] MakeCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++)
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }

    static uint Crc32(byte[] typeBytes, byte[] data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (byte b in typeBytes) crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        foreach (byte b in data) crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFF;
    }

    // =====================================================================
    // Archive Utilities
    // =====================================================================

    static byte[] Yaz0Decompress(byte[] src)
    {
        if (src.Length < 16) throw new Exception("Invalid Yaz0 data");
        uint decompSize = (uint)((src[4] << 24) | (src[5] << 16) | (src[6] << 8) | src[7]);
        byte[] dst = new byte[decompSize];
        int srcPos = 16, dstPos = 0;

        while (dstPos < decompSize && srcPos < src.Length)
        {
            byte header = src[srcPos++];
            for (int bit = 7; bit >= 0 && dstPos < decompSize && srcPos < src.Length; bit--)
            {
                if ((header & (1 << bit)) != 0)
                {
                    dst[dstPos++] = src[srcPos++];
                }
                else
                {
                    if (srcPos + 1 >= src.Length) break;
                    byte b1 = src[srcPos++], b2 = src[srcPos++];
                    int dist = ((b1 & 0x0F) << 8) | b2;
                    int copyPos = dstPos - dist - 1;
                    int length = (b1 >> 4) == 0 ? (srcPos < src.Length ? src[srcPos++] + 0x12 : 0) : (b1 >> 4) + 2;
                    for (int j = 0; j < length && dstPos < decompSize; j++)
                        dst[dstPos++] = (copyPos >= 0 && copyPos < dstPos) ? dst[copyPos++] : (byte)0;
                }
            }
        }
        return dst;
    }

    /// <summary>
    /// Extract all files from a SARC archive, returning name+data pairs.
    /// </summary>
    static List<(string name, byte[] data)> ExtractFromSarc(byte[] data)
    {
        var result = new List<(string, byte[])>();
        if (data.Length < 20) return result;

        using var reader = new BinaryReader(new MemoryStream(data));
        reader.ReadUInt32(); // "SARC"
        reader.ReadUInt16(); // header len
        reader.ReadUInt16(); // bom
        reader.ReadUInt32(); // file size
        uint dataOffset = reader.ReadUInt32();
        reader.ReadUInt16(); // version
        reader.ReadUInt16(); // reserved

        reader.ReadUInt32(); // "SFAT"
        reader.ReadUInt16(); // header length
        ushort nodeCount = reader.ReadUInt16();
        reader.ReadUInt32(); // hash key

        var nodes = new List<(uint nameOffset, uint dataStart, uint dataEnd)>();
        for (int i = 0; i < nodeCount; i++)
        {
            reader.ReadUInt32(); // hash
            uint attr = reader.ReadUInt32();
            uint nameOfs = (attr & 0x00FFFFFF) * 4;
            uint start = reader.ReadUInt32();
            uint end = reader.ReadUInt32();
            nodes.Add((nameOfs, start, end));
        }

        reader.ReadUInt32(); // "SFNT"
        reader.ReadUInt16(); // header length
        reader.ReadUInt16(); // reserved
        long sfntDataStart = reader.BaseStream.Position;

        foreach (var (nameOffset, dataStart, dataEnd) in nodes)
        {
            reader.BaseStream.Position = sfntDataStart + nameOffset;
            var nameBytes = new List<byte>();
            byte b;
            while ((b = reader.ReadByte()) != 0 && nameBytes.Count < 256)
                nameBytes.Add(b);
            string name = System.Text.Encoding.UTF8.GetString(nameBytes.ToArray());

            uint absStart = dataOffset + dataStart;
            uint size = dataEnd - dataStart;
            if (absStart + size <= data.Length)
            {
                byte[] fileData = new byte[size];
                Array.Copy(data, absStart, fileData, 0, size);
                result.Add((name, fileData));
            }
        }
        return result;
    }
}
