# BlitzMapUniter

A Godot 4.6+ editor plugin for viewing and editing Splatoon 2 map layouts stored in BYAML format. Load map archives (`.szs`, `.byaml`, `.pack`), visualize objects with 3D models, edit transforms/parameters/links, and save back to game-compatible formats.

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Building from Source](#building-from-source)
  - [1. Clone the Repository](#1-clone-the-repository)
  - [2. Build the oead Library (C++)](#2-build-the-oead-library-c)
  - [3. Build the GDExtension Wrapper](#3-build-the-gdextension-wrapper)
  - [4. Build the BfresToGltf Model Converter](#4-build-the-bfrestogltf-model-converter)
  - [5. Build the Model Cache](#5-build-the-model-cache)
  - [6. Set Up the Godot Project](#6-set-up-the-godot-project)
- [Configuration](#configuration)
- [Usage Guide](#usage-guide)
  - [Opening a Map](#opening-a-map)
  - [Navigating the Viewport](#navigating-the-viewport)
  - [Editing Objects](#editing-objects)
  - [Adding Objects and Rails](#adding-objects-and-rails)
- [Actor Database](#actor-database)
- [Tools Reference](#tools-reference)
- [Coordinate System](#coordinate-system)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Features

- **Load** Splatoon 2 map files: `.byml` (raw BYAML), `.szs` (Yaz0-compressed SARC), and `Map.pack` archives
- **3D Visualization** with cached GLTF models converted from game BFRES files
- **Transform Editing** via Godot's native 3D gizmos (move, rotate, scale) with automatic coordinate conversion
- **Parameter Inspector** with typed editors (bool/int/float/string), tooltips, and descriptions
- **Link Visualization** and navigation between connected objects
- **Rail Editing** with linear and Bézier curve support, dynamic line rendering
- **Area Objects** displayed as semi-transparent volumes with per-type icons
- **Add/Delete** objects and rails with full undo/redo support
- **Save** to BYML, SZS, or Pack format with SARC alignment preservation
- **4,300+ Actor Database** with parameters extracted from real game maps

---

## Prerequisites

### All Platforms

| Tool | Version | Purpose |
|------|---------|---------|
| [Godot Engine](https://godotengine.org/download) | 4.6+ | Editor and runtime |
| [CMake](https://cmake.org/download/) | 3.10+ | Build oead library |
| [SCons](https://scons.org/) | 4.0+ | Build GDExtension |
| [Python](https://www.python.org/downloads/) | 3.7+ | SCons, utility scripts |
| [.NET SDK](https://dotnet.microsoft.com/download) | 8.0+ | Build BfresToGltf converter |
| C++17 Compiler | See below | Compile oead and GDExtension |

### Platform-Specific Compilers

**Linux:**
```bash
# Arch
sudo pacman -S base-devel cmake python python-pip scons
```

**Windows:**
- Install [Visual Studio 2022](https://visualstudio.microsoft.com/) with the **"Desktop development with C++"** workload, OR
- Install [MinGW-w64](https://www.mingw-w64.org/) (GCC 12+)
- Install [CMake](https://cmake.org/download/) (add to PATH)
- Install Python 3 and run: `pip install scons`

**macOS:**
```bash
xcode-select --install        # Xcode command-line tools
brew install cmake python scons
```

### Optional

| Tool | Purpose |
|------|---------|
| [pycryptodome](https://pypi.org/project/pycryptodome/) | Decrypt nisasyst-encrypted ActorDb files (`pip3 install pycryptodome`) |

---

## Project Structure

```
BlitzMapUniter/
├── project/                          # Godot 4.6+ project (open this in Godot)
│   ├── project.godot                 # Godot project configuration
│   ├── bin/
│   │   └── oead_gdext.gdextension   # GDExtension library mapping
│   └── addons/blitz_map_uniter/      # Main plugin
│       ├── plugin.cfg                # Plugin metadata
│       ├── plugin.gd                 # Plugin entry point
│       ├── core/                     # Data models (GDScript)
│       │   ├── actor_database.gd     # Actor DB loader & lookup
│       │   ├── byaml_document.gd     # BYAML/SZS/Pack file I/O
│       │   ├── map_object.gd         # Map actor data model
│       │   ├── map_rail.gd           # Rail data model
│       │   ├── map_rail_point.gd     # Rail point data model
│       │   ├── bfres_loader.gd       # GLTF model cache loader
│       │   └── blitz_settings.gd     # Editor settings manager
│       ├── editor/                   # UI components (GDScript)
│       │   ├── map_editor_dock.gd    # Editor dock panel
│       │   └── map_inspector_plugin.gd # Custom inspector
│       ├── data/                     # Static data
│       │   ├── actor_db.json         # Actor definitions (4,300+ actors)
│       │   ├── param_descriptions.json # IDA-verified param docs
│       │   └── icons/                # Per-type area/object icons
│       └── bin/                      # Compiled GDExtension binaries
│
├── gdext/                            # C++ GDExtension source
│   ├── SConstruct                    # SCons build script
│   ├── src/
│   │   ├── oead_wrapper.cpp          # oead → Godot bridge
│   │   ├── oead_wrapper.h            # Class declarations
│   │   └── register_types.cpp        # GDExtension registration
│   └── godot-cpp/                    # Git submodule: Godot C++ bindings
│
├── oead/                             # Git submodule: Nintendo format parser
│
├── tools/
│   ├── BfresToGltf/                  # BFRES → GLTF converter (C# .NET 8)
│   └── nisasyst3.py                  # External nisasyst decryption script
│
├── BfresLibrary/                     # Git submodule: BFRES format library (C#, used by BfresToGltf)
```

---

## Building from Source

### 1. Clone the Repository

```bash
git clone --recurse-submodules https://github.com/YOUR_USERNAME/BlitzMapUniter.git
cd BlitzMapUniter
```

### 2. Build the oead Library (C++)

The oead library must be compiled as static libraries before building the GDExtension.

**Linux / macOS:**
```bash
cd oead
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build . -j$(nproc)
cd ../..
```

**Windows (Visual Studio):**
```cmd
cd oead
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64 -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release
cd ..\..
```

**Windows (MinGW):**
```cmd
cd oead
mkdir build && cd build
cmake .. -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build . -j%NUMBER_OF_PROCESSORS%
cd ..\..
```

**Verify:** After building, you should see these files in `oead/build/`:
```
liboead.a  (or oead.lib on MSVC)
liboead_res.a
lib/rapidyaml/libryml.a
lib/libyaml/libyaml.a
lib/zlib-ng/libzlib.a
lib/abseil/absl/.../*.a
```

### 3. Build the GDExtension Wrapper

The GDExtension wraps oead's BYML, SARC, and Yaz0 functionality for GDScript access.

**Linux:**
```bash
cd gdext
scons target=template_debug -j$(nproc)    # Debug build
scons target=template_release -j$(nproc)  # Release build (optional)
cd ..
```

**Windows:**
```cmd
cd gdext
scons target=template_debug platform=windows -j%NUMBER_OF_PROCESSORS%
scons target=template_release platform=windows -j%NUMBER_OF_PROCESSORS%
cd ..
```

**macOS:**
```bash
cd gdext
scons target=template_debug platform=macos -j$(sysctl -n hw.ncpu)
cd ..
```

**Output:** The compiled library is placed directly into the plugin directory:
```
project/addons/blitz_map_uniter/bin/liboead_gdext.<platform>.<target>.<arch>
```

For example:
- Linux: `liboead_gdext.linux.template_debug.x86_64`
- Windows: `liboead_gdext.windows.template_debug.x86_64.dll`
- macOS: `liboead_gdext.macos.template_debug.framework`

### 4. Build the BfresToGltf Model Converter

This CLI tool converts Splatoon 2 model files (`.szs`/`.bfres`) to GLTF Binary (`.glb`) format that Godot can load natively.

```bash
cd tools/BfresToGltf
dotnet build -c Release
cd ../..
```

The built executable will be at:
- **Linux/macOS:** `tools/BfresToGltf/bin/Release/net8.0/BfresToGltf`
- **Windows:** `tools/BfresToGltf/bin/Release/net8.0/BfresToGltf.exe`

For a self-contained single-file build (no .NET runtime required):

```bash
cd tools/BfresToGltf
# Linux
dotnet publish -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true
# Windows
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
# macOS
dotnet publish -c Release -r osx-x64 --self-contained -p:PublishSingleFile=true
cd ../..
```

### 5. Build the Model Cache

To display 3D models in the editor, you need to convert game model files to GLTF format.

**Prerequisites:**
- A legitimate Splatoon 2 dump with extracted model files (`.szs` archives from the `Model` folder)
- The BfresToGltf tool built in step 4

**Option A: Batch convert (recommended)**

Place your extracted `.szs` model files in the `Model/` directory, then run:

```bash
# Linux/macOS
./tools/BfresToGltf/bin/Release/net8.0/BfresToGltf Model/ ModelCache/ --batch

# Windows
tools\BfresToGltf\bin\Release\net8.0\BfresToGltf.exe Model\ ModelCache\ --batch
```

This processes all `.szs` and `.bfres` files, outputting `.glb` files to `Modelcache/`.

**Option B: Convert from within Godot**

Configure the converter path in the plugin settings (see [Configuration](#configuration)), then use the batch convert button in the editor dock.

**Option C: Single file conversion**

```bash
BfresToGltf path/to/model.szs ModelCache/
```

### 6. Set Up the Godot Project

1. Open **Godot 4.6+**
2. Click **Import** and select `project/project.godot`
3. The editor will import the project; if you see GDExtension errors, ensure step 3 completed successfully
4. Go to **Project → Project Settings → Plugins** and enable **BlitzMapUniter**
5. The **MapEditor** dock should appear in the right panel. You can also access the dock from **Editor → Editor Docks → MapEditor**

---

## Configuration

After enabling the plugin, click the **⚙** (gear) button in the MapEditor dock to configure:

| Setting | Description | Example |
|---------|-------------|---------|
| **Model Folder** | Path to extracted game model files (`.szs`/`.bfres`) | `/path/to/splatoon2/Model` |
| **ActorDb File** | Path to an ActorDb `.byml` file for additional actor data | `/path/to/ActorDb.byml` |
| **Cache Folder** | Directory for converted `.glb` model files | `/path/to/BlitzMapUniter/ModelCache` |
| **Converter Path** | Path to the `BfresToGltf` executable | `/path/to/BfresToGltf` |

These settings are stored in Godot's EditorSettings and persist across sessions.

---

## Usage Guide

### Opening a Map

1. Create a new **3D scene** (Node3D root)
2. In the **MapEditor** dock (right panel):
   - Click **Map.pack** to browse a `Map.pack` archive and select an individual map entry
   - Click **File** to open a standalone `.szs` or `.byaml` map file

### Navigating the Viewport

Objects are displayed in the 3D viewport with models (if cached) or colored placeholders:

| Color | Type | Examples |
|-------|------|---------|
| Blue boxes | General objects | `Obj_*` |
| Red spheres | Enemies | `Enm_*` |
| Gold boxes | Lifts | `Lft_*` |
| Purple cylinders | NPCs | `Npc_*` |
| Orange lines | Rails | Linear and Bézier curves |

- **Area objects** display a per-type icon sprite and can have their volume viewed through selection. `PaintedArea_Cylinder` uniquely always displays a semi-transparent volume for clearer visualization
- **Rails** render as connected lines; Bézier rails show smooth curves through control points
- **Links** between objects are visualized as debug lines in the viewport

### Editing Objects

**Transforms:** Select any object and use Godot's native 3D gizmos to move, rotate, or scale. Changes are automatically synced to the map data coordinate system on save.

**Parameters:** When an object is selected, the **Inspector** panel displays editable parameters grouped by component:
- Boolean → checkbox
- Numeric → spinner
- String → text field
- Hover over labels to see IDA-verified parameter descriptions

**Links:** The Inspector shows all links for the selected object. Click the **→** button to navigate to a linked object. Use **+ Add Link** to create new connections.

**Actor Type:** Change the **Map Actor** (UnitConfigName) field in the Inspector to change an object's actor type. Parameters will dynamically reload to match the new actor's definition.

### Adding Objects and Rails

**Objects:**
1. Click **+ Obj** in the dock toolbar
2. Search for an actor type from the database (4,300+ actors available)
3. Select a layer (default: `Cmn`)
4. Click **Add** — the object appears at the origin

**Rails:**
1. Click **+ Rail** in the dock toolbar
2. Set the rail name, type (Linear or Bézier), and point count
3. Click **Add** — points are spaced along the X axis
4. Select individual rail points to reposition them

**Deletion:** Select any map node and press **Delete** to remove it from the document.

---

## Actor Database

The plugin ships with `actor_db.json` containing **4,300+ actor definitions** extracted from:
- `Mush.release.pack` (Mush/ActorDb.release.byml) - 5.5.2
- Standalone ActorDb files from versions 1.0.0 through 3.1.0
- Parameter data mined from 274 maps in 5.5.2's `Map.pack` (63,000+ objects)

Each actor entry includes:
- **class** — internal class name (e.g., `Lift`)
- **res_name** — BFRES model resource name
- **fmdb_name** — FMDL model name within the BFRES
- **params** — typed parameter definitions with defaults
- **link_types** — supported link type connections

### Loading Additional ActorDb Files

To load actor data from other game versions:

1. Place ActorDb `.byml` files in the `ActorDbRef/` folder
2. Files from versions **1.0.0–2.2.0** are raw BYML and load directly
3. Files from versions **2.3.0+** are nisasyst-encrypted; decrypt first:

```bash
pip3 install pycryptodome  # One-time setup
python3 tools/nisasyst3.py ActorDb.230.byml "Mush/ActorDb.release.byml" ActorDb.230.dec.byml
```

4. Configure the decrypted file path in the plugin's **ActorDb File** setting

---

## Tools Reference

### BfresToGltf

C# CLI tool for converting Nintendo BFRES model archives to GLTF Binary format.

```
Usage: BfresToGltf <input_path> <output_dir> [--batch]

Arguments:
  input_path  Path to .bfres/.szs file, or directory (with --batch)
  output_dir  Directory to write .glb files

Options:
  --batch     Process all .szs/.bfres files in the input directory
```

Each FMDL model inside a BFRES is exported as a separate `.glb` file. Textures are extracted from embedded BNTX, deswizzled, BC-decompressed to RGBA, and embedded as PNG in the GLTF material.

### nisasyst3.py

Python 3 decryption utility for Splatoon 2's nisasyst-encrypted resources.

```
Usage: python3 nisasyst3.py <encrypted_file> <resource_path> [output_file]

Arguments:
  encrypted_file  Path to the encrypted file
  resource_path   Original game resource path (used as decryption key seed)
  output_file     Optional output path (defaults to input + .dec)

Example:
  python3 tools/nisasyst3.py ActorDb.230.byml "Mush/ActorDb.release.byml"
```

Requires: `pycryptodome` (`pip3 install pycryptodome`)

---

## Coordinate System

Splatoon 2 uses a **left-handed Y-up** coordinate system. Godot uses **right-handed Y-up**.

The plugin automatically converts between them:

| Axis | Game → Godot | Godot → Game |
|------|-------------|-------------|
| **Position X** | Negated | Negated |
| **Position Y** | Unchanged | Unchanged |
| **Position Z** | Negated | Negated |
| **Rotation** | ZYX Euler order, Y and Z negated | Reversed |

This conversion is mathematically lossless — exact original values are restored on save.

---

## Troubleshooting

### GDExtension fails to load
- Ensure the oead library was built successfully (check for `.a`/`.lib` files in `oead/build/`)
- Ensure the GDExtension was built for your platform (`scons target=template_debug`)
- Check that `project/bin/oead_gdext.gdextension` points to the correct library paths
- On Windows, ensure MSVC redistributables are installed

### "OeadByml::to_binary failed" when saving
- This typically indicates corrupted BYAML data in the document
- Ensure the map file loaded without errors
- Check the Godot output panel for specific error messages

### Models not showing
- Verify the **Cache Folder** setting points to a directory containing `.glb` files
- Run batch conversion if you haven't yet: `BfresToGltf Model/ ModelCache/ --batch`
- Check the Godot output for `ModelCache:` messages indicating load failures

### oead CMake build fails
- Ensure all git submodules are initialized: `cd oead && git submodule update --init --recursive`
- On Windows, use a Developer Command Prompt or ensure CMake can find your compiler
- Minimum CMake version: 3.10

### BfresToGltf build fails
- Requires .NET 8.0 SDK: `dotnet --version` should show 8.0+
- Ensure BfresLibrary subproject is present (check `BfresLibrary/BfresLibrary/BfresLibrary.csproj`)

### Plugin doesn't appear in Godot
- Open `project/project.godot` in Godot 4.6+
- Go to **Project → Project Settings → Plugins**
- Enable **BlitzMapUniter** if it's listed but disabled
- If not listed, ensure `project/addons/blitz_map_uniter/plugin.cfg` exists

---

## License

This project is provided as-is for educational and modding purposes. It does not include any proprietary Nintendo assets. Users must provide their own legally obtained game files for model visualization.

- **oead**: GPLv2
- **godot-cpp**: MIT License (© Godot Engine contributors)
- **BfresLibrary**: MIT License (© KillzXGaming)
- **abseil-cpp**: Apache 2.0 License (© Google)
