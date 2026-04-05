#include "oead_wrapper.h"

#include <oead/byml.h>
#include <oead/sarc.h>
#include <oead/yaz0.h>
#include <oead/types.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <string>
#include <cstring>

// ============================================================
// Helpers: Convert between oead and Godot types
// ============================================================

static std::vector<u8> pba_to_vec(const PackedByteArray &pba) {
    std::vector<u8> v(pba.size());
    if (pba.size() > 0) {
        memcpy(v.data(), pba.ptr(), pba.size());
    }
    return v;
}

static PackedByteArray vec_to_pba(const std::vector<u8> &v) {
    PackedByteArray pba;
    pba.resize(v.size());
    if (v.size() > 0) {
        memcpy(pba.ptrw(), v.data(), v.size());
    }
    return pba;
}

static void log_error(const char* msg) {
    UtilityFunctions::printerr(msg);
}

// Forward declare
static Variant byml_to_variant(const oead::Byml &node);
static oead::Byml variant_to_byml(const Variant &v);

static Variant byml_to_variant(const oead::Byml &node) {
    switch (node.GetType()) {
        case oead::Byml::Type::Null:
            return Variant();
        case oead::Byml::Type::String: {
            const auto &s = node.GetString();
            return String::utf8(s.c_str(), s.size());
        }
        case oead::Byml::Type::Bool:
            return node.GetBool();
        case oead::Byml::Type::Int:
            return node.GetInt();
        case oead::Byml::Type::UInt:
            return (int64_t)node.GetUInt();
        case oead::Byml::Type::Float:
            return node.GetFloat();
        case oead::Byml::Type::Int64:
            return node.GetInt64();
        case oead::Byml::Type::UInt64:
            return (int64_t)node.GetUInt64();
        case oead::Byml::Type::Double:
            return node.GetDouble();
        case oead::Byml::Type::Hash: {
            Dictionary dict;
            for (const auto &[key, val] : node.GetHash()) {
                std::string k(key);
                dict[String::utf8(k.c_str(), k.size())] = byml_to_variant(val);
            }
            return dict;
        }
        case oead::Byml::Type::Array: {
            Array arr;
            for (const auto &elem : node.GetArray()) {
                arr.push_back(byml_to_variant(elem));
            }
            return arr;
        }
        case oead::Byml::Type::Binary: {
            const auto &bin = node.GetBinary();
            PackedByteArray pba;
            pba.resize(bin.size());
            if (bin.size() > 0) {
                memcpy(pba.ptrw(), bin.data(), bin.size());
            }
            return pba;
        }
        default:
            return Variant();
    }
}

static oead::Byml variant_to_byml(const Variant &v) {
    switch (v.get_type()) {
        case Variant::NIL:
            return oead::Byml{};
        case Variant::BOOL:
            return oead::Byml((bool)v);
        case Variant::INT: {
            int64_t val = (int64_t)v;
            if (val >= INT32_MIN && val <= INT32_MAX) {
                return oead::Byml(oead::S32(static_cast<int32_t>(val)));
            }
            return oead::Byml(oead::S64(val));
        }
        case Variant::FLOAT:
            return oead::Byml(oead::F32(static_cast<float>((double)v)));
        case Variant::STRING: {
            String s = v;
            std::string str(s.utf8().get_data());
            return oead::Byml(std::make_unique<std::string>(std::move(str)));
        }
        case Variant::DICTIONARY: {
            Dictionary d = v;
            auto hash = std::make_unique<oead::Byml::Hash>();
            Array keys = d.keys();
            for (int i = 0; i < keys.size(); i++) {
                String key = keys[i];
                (*hash)[std::string(key.utf8().get_data())] = variant_to_byml(d[keys[i]]);
            }
            return oead::Byml(std::move(hash));
        }
        case Variant::ARRAY: {
            Array a = v;
            auto arr = std::make_unique<oead::Byml::Array>();
            for (int i = 0; i < a.size(); i++) {
                arr->push_back(variant_to_byml(a[i]));
            }
            return oead::Byml(std::move(arr));
        }
        case Variant::PACKED_BYTE_ARRAY: {
            PackedByteArray pba = v;
            auto bin = std::make_unique<std::vector<u8>>(pba.size());
            if (pba.size() > 0) {
                memcpy(bin->data(), pba.ptr(), pba.size());
            }
            return oead::Byml(std::move(bin));
        }
        default: {
            String msg = String("variant_to_byml: unsupported type ") + String::num_int64(v.get_type()) + " (" + Variant::get_type_name(v.get_type()) + ")";
            UtilityFunctions::printerr(msg);
            return oead::Byml{};
        }
    }
}

// ============================================================
// OeadYaz0
// ============================================================

void OeadYaz0::_bind_methods() {
    ClassDB::bind_static_method("OeadYaz0", D_METHOD("decompress", "data"), &OeadYaz0::decompress);
    ClassDB::bind_static_method("OeadYaz0", D_METHOD("compress", "data", "alignment"), &OeadYaz0::compress, DEFVAL(0));
}

PackedByteArray OeadYaz0::decompress(const PackedByteArray &data) {
    try {
        auto input = pba_to_vec(data);
        auto result = oead::yaz0::Decompress(input);
        return vec_to_pba(result);
    } catch (...) {
        log_error("OeadYaz0::decompress failed");
        return PackedByteArray();
    }
}

PackedByteArray OeadYaz0::compress(const PackedByteArray &data, int alignment) {
    try {
        auto input = pba_to_vec(data);
        auto result = oead::yaz0::Compress(input, alignment);
        return vec_to_pba(result);
    } catch (...) {
        log_error("OeadYaz0::compress failed");
        return PackedByteArray();
    }
}

// ============================================================
// OeadSarc
// ============================================================

void OeadSarc::_bind_methods() {
    ClassDB::bind_static_method("OeadSarc", D_METHOD("parse", "data"), &OeadSarc::parse);
    ClassDB::bind_static_method("OeadSarc", D_METHOD("parse_with_metadata", "data"), &OeadSarc::parse_with_metadata);
    ClassDB::bind_static_method("OeadSarc", D_METHOD("build", "files", "endian", "min_alignment"), &OeadSarc::build, DEFVAL(0), DEFVAL(0));
}

Array OeadSarc::parse(const PackedByteArray &data) {
    Array result;
    try {
        auto input = pba_to_vec(data);
        oead::Sarc sarc(input);
        for (const auto &file : sarc.GetFiles()) {
            Dictionary entry;
            std::string fname(file.name);
            entry["name"] = String::utf8(fname.c_str(), fname.size());
            PackedByteArray file_data;
            file_data.resize(file.data.size());
            if (file.data.size() > 0) {
                memcpy(file_data.ptrw(), file.data.data(), file.data.size());
            }
            entry["data"] = file_data;
            result.push_back(entry);
        }
    } catch (...) {
        log_error("OeadSarc::parse failed");
    }
    return result;
}

Dictionary OeadSarc::parse_with_metadata(const PackedByteArray &data) {
    Dictionary result;
    Array files;
    int endian = 0;
    int min_alignment = 4;
    try {
        auto input = pba_to_vec(data);
        oead::Sarc sarc(input);

        // Extract endianness from the SARC
        endian = (sarc.GetEndianness() == oead::util::Endianness::Big) ? 1 : 0;

        // Compute minimum alignment by checking file data offsets
        // The SARC data offset is stored in the header; check alignment of file entries
        min_alignment = sarc.GuessMinAlignment();

        for (const auto &file : sarc.GetFiles()) {
            Dictionary entry;
            std::string fname(file.name);
            entry["name"] = String::utf8(fname.c_str(), fname.size());
            PackedByteArray file_data;
            file_data.resize(file.data.size());
            if (file.data.size() > 0) {
                memcpy(file_data.ptrw(), file.data.data(), file.data.size());
            }
            entry["data"] = file_data;
            files.push_back(entry);
        }
    } catch (...) {
        log_error("OeadSarc::parse_with_metadata failed");
    }
    result["files"] = files;
    result["endian"] = endian;
    result["min_alignment"] = min_alignment;
    return result;
}

PackedByteArray OeadSarc::build(const Array &files, int endian, int min_alignment) {
    try {
        oead::SarcWriter writer;
        writer.SetEndianness(endian == 0 ? oead::util::Endianness::Little : oead::util::Endianness::Big);
        if (min_alignment > 0) {
            writer.SetMinAlignment(min_alignment);
        }
        for (int i = 0; i < files.size(); i++) {
            Dictionary entry = files[i];
            String name = entry["name"];
            PackedByteArray file_data = entry["data"];
            std::vector<u8> data_vec(file_data.size());
            if (file_data.size() > 0) {
                memcpy(data_vec.data(), file_data.ptr(), file_data.size());
            }
            writer.m_files[std::string(name.utf8().get_data())] = std::move(data_vec);
        }
        auto [alignment, data] = writer.Write();
        return vec_to_pba(data);
    } catch (...) {
        log_error("OeadSarc::build failed");
        return PackedByteArray();
    }
}

// ============================================================
// OeadByml
// ============================================================

void OeadByml::_bind_methods() {
    ClassDB::bind_static_method("OeadByml", D_METHOD("from_binary", "data"), &OeadByml::from_binary);
    ClassDB::bind_static_method("OeadByml", D_METHOD("to_binary", "root", "big_endian", "version"), &OeadByml::to_binary, DEFVAL(false), DEFVAL(3));
}

Variant OeadByml::from_binary(const PackedByteArray &data) {
    try {
        auto input = pba_to_vec(data);
        auto byml = oead::Byml::FromBinary(input);
        return byml_to_variant(byml);
    } catch (...) {
        log_error("OeadByml::from_binary failed");
        return Variant();
    }
}

PackedByteArray OeadByml::to_binary(const Variant &root, bool big_endian, int version) {
    try {
        auto byml = variant_to_byml(root);
        auto result = byml.ToBinary(big_endian, version);
        return vec_to_pba(result);
    } catch (const std::exception &e) {
        String msg = String("OeadByml::to_binary failed: ") + e.what();
        UtilityFunctions::printerr(msg);
        return PackedByteArray();
    } catch (...) {
        log_error("OeadByml::to_binary failed (unknown exception)");
        return PackedByteArray();
    }
}
