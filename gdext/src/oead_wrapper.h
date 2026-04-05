#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

using namespace godot;

// Wraps oead::yaz0 for GDScript
class OeadYaz0 : public RefCounted {
    GDCLASS(OeadYaz0, RefCounted);
protected:
    static void _bind_methods();
public:
    static PackedByteArray decompress(const PackedByteArray &data);
    static PackedByteArray compress(const PackedByteArray &data, int alignment = 0);
};

// Wraps oead::Sarc for GDScript
class OeadSarc : public RefCounted {
    GDCLASS(OeadSarc, RefCounted);
protected:
    static void _bind_methods();
public:
    // Returns Array of Dictionary {name: String, data: PackedByteArray}
    static Array parse(const PackedByteArray &data);
    // Returns Dictionary with metadata: {files: Array, endian: int, min_alignment: int}
    static Dictionary parse_with_metadata(const PackedByteArray &data);
    // files: Array of Dictionary {name: String, data: PackedByteArray}
    // endian: 0 = little, 1 = big
    // min_alignment: minimum data alignment within the SARC (0 = auto-detect from file extensions)
    static PackedByteArray build(const Array &files, int endian = 0, int min_alignment = 0);
};

// Wraps oead::Byml for GDScript
class OeadByml : public RefCounted {
    GDCLASS(OeadByml, RefCounted);
protected:
    static void _bind_methods();
public:
    // Parse BYML binary to Variant tree (Dictionary/Array/String/int/float/bool/null)
    static Variant from_binary(const PackedByteArray &data);
    // Serialize Variant tree back to BYML binary
    // big_endian: false for little-endian (Splatoon 2 map files), true for big-endian (ActorDb)
    // version: BYML version (typically 3)
    static PackedByteArray to_binary(const Variant &root, bool big_endian = false, int version = 3);
};
