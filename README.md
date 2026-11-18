# Throttle Trace Car Switcher

An unofficial mod for [Throttle Trace](https://store.steampowered.com/app/4535730/) that replaces the game's car model with other car models and lets you race a class of cars in quick races.

- **`mods/car_switcher/mod.gd`** swaps the model of every car (player, AI, ghosts, replays, menu previews) for a model from `mods/car_switcher/cars/`. It adds two dropdowns to the quick race popup, **Class** and **Your Car**. The AI field is dealt from the chosen class, and every car in the class is used once before any car repeats. Wheels spin with the car's speed.
- **`mods/car_switcher/car_spin.gd`** and **`car_gravity.gd`** apply a class's performance values (see [Settings](#settings)): wheelspin and corner-exit grip scaled to the engine power, real slope gravity, DRS and ERS turned off.
- **`mods/car_switcher/settings.cfg`** holds the performance values per class and the car for each career team.

Only the look of the cars changes. Physics, collisions and sound stay the game's own, apart from the class performance values.

Built for Throttle Trace v0.42.0 (Godot 4.6). Game updates may break it.

**No cars are included.** Car models are not part of this repository; the mod needs your own models in the `cars/` folder (see [Cars](#cars)). Without any, every car keeps the game's model.

## Install

### 1. Install the mod loader

The game has no built-in mod support. Install the [Throttle Trace Mod Loader](https://github.com/NoelJarling/Throttle-Trace-Mod-Loader) first, including the `--enable-mods` launch option.

The class performance values need a loader with `extend_script`. Without it the cars are still swapped, and the log shows an error that wheelspin ignores engine power.

### 2. Copy `mods/` into the game's user data folder

| OS      | User data folder                                    |
|---------|-----------------------------------------------------|
| Linux   | `~/.local/share/godot/app_userdata/Throttle Trace/` |
| Windows | `%APPDATA%\Godot\app_userdata\Throttle Trace\`      |

Afterwards the user data folder should look like this:

```
Throttle Trace/            (user data folder)
├── mod_loader/
│   └── mod_loader.gd
├── mods/
│   └── car_switcher/
│       ├── mod.gd
│       ├── car_spin.gd
│       ├── car_gravity.gd
│       ├── settings.cfg
│       └── cars/
│           └── <car>/
│               ├── car.glb
│               └── car.cfg
```

## Usage

1. Open a quick race. Under **Laps** there are two new rows:
   - **Class**: the cars of this class make up the field. **None** = the game's own car for everyone.
   - **Your Car**: your car from the class. **Random** = a random car from the class.
2. Press **Start race**. The choice holds for this race and its restarts. Leaving the track resets it.

Career teams listed in `settings.cfg` `[teams]` always drive their own car.

The cars and `settings.cfg` are read once at game start. Restart the game after changing them.

## Cars

Each car is a folder in `mods/car_switcher/cars/`. The folder name is the car's id.

### `car.glb`

A glTF binary in the game's car model space: metres, +Y up, +Z towards the nose, +X to the car's left, origin and ground level as in the game's own car model. Its top-level nodes replace the game's parts of the same name:

| Node | Required | Content |
|---|---|---|
| `Chassis` | yes | the body |
| `FrontWing` | yes | front wing |
| `RearWing` | yes | rear wing (the game retires a car without one) |
| `FrontLeft`, `FrontRight`, `RearLeft`, `RearRight` | no | wheels, placed at the node position. Surface 0 = tyre (gets the game's tyre material, so compound and wear colours work), further surfaces keep their own materials |
| `Glass` | no | see-through glass, drawn alpha-blended |

`Chassis`, `FrontWing` and `RearWing` have one surface each and share one texture atlas (the base colour texture of the `Chassis` material). Texels with alpha below 0.5 are cut out. An optional metallic-roughness texture on the `Chassis` material sets the gloss: R clearcoat, G roughness, B metallic, A specular.

The game's suspension, steering wheel, number and driver are hidden.

### `car.cfg` (optional)

```ini
[car]
name="Red Bull Racing"
classes=["F1 2026"]
```

- `name`: shown in the **Your Car** dropdown. Default: the folder name.
- `classes`: the classes the car belongs to. Every class of any car appears in the **Class** dropdown.

## Settings

`mods/car_switcher/settings.cfg`:

```ini
[performance]
"GT3"={"engine_power": 0.363, "drag_coefficient": 0.0055, "braking_power": 0.42, "base_cornering_speed": 0.514, "gravity": 9.81, "drs": false, "ers": false}

[teams]
"Red Bull Racing"="f1_26_rb"
```

### `[performance]`

Values for races whose field is set to that class (class names are not case sensitive). Not used in time trials or multiplayer.

| Key | Value |
|---|---|
| any float field of the game's gameplay settings (`engine_power`, `drag_coefficient`, `drag_exponent`, `braking_power`, `engine_braking`, `base_cornering_speed`, ...) | set for this race on a copy of the gameplay settings. The gameplay tab's own values stay as they are |
| `gravity` | slope gravity in m/s². The game uses 50, sized for its own car; with real-life engine values that pulls cars up and down hills far too hard |
| `drs` | `false` = no DRS for any car |
| `ers` | `false` = ERS off and the battery empty for every car |

With performance values set, the wheelspin limit and the grip lost on throttle out of corners follow `engine_power`. Without them all cars behave like the game's.

The values in `settings.cfg` are fitted to real lap times at Laguna Seca for GT3, Hypercar / LMDh / LMH, MX5 Cup and the Corvette C7 Stingray.

### `[teams]`

`"<career team name>"="<car folder>"`: every driver of that team drives this car. Your own team's car replaces **Your Car**. Team names come from the career database and are not case sensitive.

## Uninstall

Delete `mods/car_switcher/` from the user data folder.
