# RTV Mod Loader

A GDScript mod loader for [Road to Vostok](https://store.steampowered.com/app/1963610/Road_to_Vostok/) (Godot 4.6). Loads `.vmz`, `.zip`, and `.pck` mod archives at runtime with an in-game mod manager UI.

## Features

- Loads mod archives from a `mods/` directory next to the game executable
- `mod.txt` manifest for mod metadata and autoload declarations
- `take_over_path` script patching with conflict detection
- In-game mod manager (enable/disable, load order, conflict summary)
- Mod compatibility analysis (lifecycle super() checks, script conflicts)
- Auto-update checking via ModWorkshop API

## Installation

### Windows

1. Copy `override.cfg` and `modloader.gd` into the **game install directory**:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```
   > Right-click the game in Steam > Manage > Browse Local Files to find the directory.
2. Create a `mods` folder in the game install directory if it doesn't exist.
3. Launch the game through Steam. You should see the **RTV Mod Loader** button in the top-left corner.

### Linux (Proton)

> Launch the game once through Steam first to create the Proton prefix.

1. Copy `override.cfg` and `modloader.gd` into the **game install directory**:
   ```
   ~/.local/share/Steam/steamapps/common/Road to Vostok/
   ```
2. Create a `mods` folder:
   ```bash
   mkdir -p ~/.local/share/Steam/steamapps/common/Road\ to\ Vostok/mods
   ```
3. Launch the game through Steam.

### Directory layout

```
Road to Vostok/
  RTV.exe
  RTV.pck
  override.cfg          <- RTV Mod Loader
  modloader.gd          <- RTV Mod Loader
  mods/                 <- mod archives go here
    my-mod.vmz
    another-mod.zip
```

## Creating a Mod

### Archive format

Mods are packaged as `.vmz` (renamed `.zip`) or `.zip` archives. The archive must contain a `mod.txt` at the root.

### mod.txt

```ini
[mod]
name="My Mod"
id="my-mod"
version="1.0.0"

[autoload]
MyModManager="res://mymod/autoload/manager.gd"
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Display name shown in the mod manager |
| `id` | Yes | Unique identifier (used for duplicate detection) |
| `version` | No | Semantic version string |
| `priority` | No | Load order (lower = earlier, default 0) |

### Autoloads

The `[autoload]` section declares scripts or scenes to instantiate and add to the scene tree at startup. Each entry maps a node name to a `res://` path inside the archive.

```ini
[autoload]
MyManager="res://mymod/manager.gd"
```

The loader will:
1. Mount the archive into `res://`
2. Load and instantiate the script/scene
3. Add it to the root as a named node

### Script patching with take_over_path

To override a game script, create a patch script that extends the original:

```gdscript
extends "res://Scripts/Door.gd"

func Interact():
    # Custom behavior
    super.Interact()
```

Then in your autoload, register the patch:

```gdscript
func _ready():
    var patch = load("res://mymod/patches/door_patch.gd")
    patch.take_over_path("res://Scripts/Door.gd")
```

The mod loader detects `take_over_path` calls and will warn about conflicts if multiple mods try to patch the same script.

### Archive structure

Files in the archive map directly to `res://` paths:

```
mod.txt                         -> read by loader (not mounted)
mymod/autoload/manager.gd      -> res://mymod/autoload/manager.gd
mymod/patches/door_patch.gd    -> res://mymod/patches/door_patch.gd
```

## Mod Manager UI

Click the **RTV Mod Loader** button in the top-left corner to open the mod manager. From here you can:

- Enable/disable individual mods
- View load order and adjust priority
- See conflict warnings and compatibility analysis
- Check for mod updates (ModWorkshop-hosted mods)

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game install directory.

## Troubleshooting

### Game won't start after installing

- Verify both `override.cfg` and `modloader.gd` are in the game directory (next to `RTV.exe`)
- Try removing all mods from `mods/` to confirm the loader itself works

### Mod not loading

- Check that the `.vmz`/`.zip` contains a valid `mod.txt` at the root
- Check the game log for `[ModLoader]` messages:
  - **Windows:** `%APPDATA%\Road to Vostok\logs\godot.log`
  - **Linux:** `~/.local/share/Steam/steamapps/compatdata/1963610/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/logs/godot.log`

### Conflict warnings

The loader warns about:
- **Script conflicts:** Multiple mods patching the same game script via `take_over_path`
- **Missing super():** Patch scripts that override lifecycle methods without calling `super()`
- **Database overrides:** Mods that replace `Database.gd` (high risk of breaking item preloads)
