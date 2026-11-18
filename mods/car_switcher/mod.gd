extends Node

const DEFAULT_CAR := "default"
const REQUIRED_PARTS := ["Chassis", "FrontWing", "RearWing"]
const GLASS_NODE := "CarSwitcherGlass"
const WHEELS := ["FrontLeft", "FrontRight", "RearLeft", "RearRight"]
const TELEPORT_DISTANCE := 5.0  # metres moved in one tick: a reset or pit teleport, the wheels don't spin
const QUICK_RACE_SCENE := "res://ui/ui_quick_race/ui_quick_race"  # without extension (.tscn / exported .scn)

# The game's car shaders paint a livery mask in the team colours; ours draw the car's own texture (livery) instead.
# Each key is a line of the game's shader, replaced by its value. All must be found, else the car isn't swapped.
const SHADER_PATCHES := {
	# Both sides are drawn, in case a model has inside-out panels.
	"shader_type spatial;": """shader_type spatial;
render_mode cull_disabled;""",

	"uniform sampler2D base_texture: source_color;": """uniform sampler2D base_texture: source_color;
uniform sampler2D car_texture: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D car_surface: hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool car_surface_on = false;""",

	# The car's texture; alpha < 0.5 = GT4 decal cut-out. tex_rgb = pure mask red, so the game's paint
	# code (and PAINT_PATCHES) treat the whole car as paint.
	"vec3 tex_rgb = texture(base_texture, UV).rgb;": """vec4 car_tex = texture(car_texture, UV);
	if (car_tex.a < 0.5) { discard; }
	vec3 car_rgb = car_tex.rgb;
	vec3 tex_rgb = vec3(1.0, 0.0, 0.0);""",

	# The car's own colours, never the team colour.
	"ALBEDO = mix(painted_albedo, fabric_albedo, fabric_mask);": "ALBEDO = car_rgb;",
}
# Cosmetic, skipped if a game update changed the line: flat, clean paint instead of the game's metal
# grain and carbon weave (no normal map, no metal, paint roughness 0.5). Cars with a surface atlas take R clearcoat,
# G roughness, B metallic, A specular from it.
const PAINT_PATCHES := {
	"NORMAL_MAP = mix(texture(metal_normal, metal_uv).rgb, texture(fabric_normal, fabric_uv).rgb, fabric_mask);": "",
	"ROUGHNESS = mix(texture(metal_roughness, metal_uv).r, texture(fabric_roughness, fabric_uv).r, fabric_mask);": "ROUGHNESS = mix(mix(0.5, 0.12, (1.0 - tinted) * lit), 0.85, fabric_mask);",
	"METALLIC = mix(texture(metal_metallic, metal_uv).r, fabric_metallic, fabric_mask);": """METALLIC = 0.0;
	if (car_surface_on) {
		vec4 car_surf = texture(car_surface, UV);
		CLEARCOAT = car_surf.r;
		CLEARCOAT_ROUGHNESS = car_surf.g;
		ROUGHNESS = car_surf.g;
		METALLIC = car_surf.b;
		SPECULAR = car_surf.a;
	}""",
}

# The game's highlight outline (replay / incident: an inverted hull in one flat colour, on the body, wings
# and tyres) ignores the texture, so it filled the GT4 cut-outs (R8: alpha-0 sheets across the car at both
# axles) as black / yellow slabs. Cosmetic, skipped if a game update changed the lines: it discards the car
# texture's cut-out texels too, only on our body parts (instance uniform car_cut, set in _place_parts).
const OUTLINE_PATCHES := {
	"uniform vec3 color : source_color = vec3(1.0, 1.0, 1.0);": """uniform vec3 color : source_color = vec3(1.0, 1.0, 1.0);
uniform sampler2D car_texture: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
instance uniform float car_cut = 0.0;""",
	"ALBEDO = color;": """if (car_cut > 0.5 && texture(car_texture, UV).a < 0.5) { discard; }
	ALBEDO = color;""",
}

var _dir: String

# For the current race only: set when the quick race popup's Start race is pressed, cleared when the track closes
var _player_type := ""  # "" = random from the field
var _field_class := ""  # "" = the game's default car for everyone

# The quick race popup's dropdowns (applied on Start race)
var _chosen_class := ""
var _chosen_player := ""

# settings.cfg and the cars on disk, read once at game start
var _teams := {}  # [teams]: lower-case career team name -> car
var _performance := {}  # [performance]: lower-case class name -> {gameplay setting: value}
var _classes := {}  # lower-case class name -> {"name": as first written, "cars": its car types sorted by name}
var _names := {}  # car type -> car.cfg name, else the folder

# The current field and grid
var _field := []  # car types the AI pick from: the chosen class's cars (empty = the game's default car)
var _bag := []  # what's left of the shuffled field for this grid: every car once before any repeats
var _bag_first := true  # the bag's first filling for this grid (leaves out a set player car)

# Loaded cars and swapped models
var _cars := {}  # car type -> { part name: { "position": Vector3, "mesh": Mesh or null } }, empty if unusable
var _shaders := {}  # the game's Shader -> its patched version (null if the game changed it)
var _swapped := []  # per swapped car: {model, wheels: [[node, radius]], last_position}


func _ready() -> void:
	_dir = get_script().resource_path.get_base_dir()
	process_physics_priority = 1000  # after the game's car step to calculate wheel rotation
	get_tree().node_added.connect(_on_node_added)

	# Read the performance / team mappings
	_read_settings()
	# Read all cars and classes
	_scan_cars()

	# Load wheelspin and gravity extensions
	var loader := get_parent()
	if loader != null and loader.has_method("extend_script"):
		loader.extend_script(_dir.path_join("car_spin.gd"), ["res://cars/car.tscn"])
	else:
		push_error("[CarSwitcher] the mod loader has no extend_script: wheelspin ignores engine power")


# Wheel spin every physics step (visual only)
func _physics_process(_delta: float) -> void:
	for i in range(_swapped.size() - 1, -1, -1):
		var car: Dictionary = _swapped[i]
		if not is_instance_valid(car.model):
			_swapped.remove_at(i)
			continue
		var model: Node3D = car.model
		if not model.is_inside_tree():
			continue
		var position := model.global_position
		if car.last_position != null:
			var forward: float = (model.global_basis.inverse() * (position - car.last_position)).z  # metres, +Z = nose
			if absf(forward) < TELEPORT_DISTANCE:
				for wheel in car.wheels:
					wheel[0].rotation.x = wrapf(wheel[0].rotation.x + forward / wheel[1], -PI, PI)
		car.last_position = position


# --- Which car a model becomes ---

## Runs before the model's own _ready(), so the game picks up the new parts by itself.
func _on_node_added(node: Node) -> void:
	if node.scene_file_path.get_basename() == QUICK_RACE_SCENE:
		_add_race_rows(node)
		return

	# The popup's choice is valid for this race only (a quick race restart keeps the same Track node)
	if node is Track and not node.tree_exiting.is_connected(_on_track_exiting):
		node.tree_exiting.connect(_on_track_exiting)

	# Otherwise we only care about CarModel nodes added to the tree
	var script: Script = node.get_script()
	if script == null or script.get_global_name() != "CarModel":
		return

	# Change the car model, parts and textures
	var parts := _load_car(_car_type_for(node))
	if not parts.is_empty():
		_apply(node, parts)

func _on_track_exiting() -> void:
	_set_class("")


## Player, AI, replay, ghost or menu preview, told apart by the model's holder.
func _car_type_for(model: Node3D) -> String:
	var holder := model.get_parent()  # race Car: CarModelPositioner; ghost and replay cars: themselves
	var car := holder.get_parent() if holder != null else null
	if car != null and "player_controller" in car and "driver" in car:
		return _race_car_type(car) # Cars in a race
	return _player_or_random()  # replays, ghosts and menu previews


## A race Car: its team's car, else the player setting / a random car.
## The game sets the car's index, team, driver and player_controller before add_child.
func _race_car_type(car: Node) -> String:
	if car.get("index") == 0:  # a new grid: track.init_with_params creates all its cars in one loop
		_bag = []
		_bag_first = true
		_set_performance(car.get("track"))
	var team = car.get("team")  # only career teams have fixed names
	var team_car: String = _teams.get(str(team.team_name).to_lower(), "") if team != null and "team_name" in team else ""
	if team_car != "":
		return team_car
	return _player_or_random() if car.get("player_controller") != null else _random_type()


## [performance] values of the field's class for this race. The cars read the
## gameplay settings in their _ready(), after this. The race gets a copy, so the gameplay tab's own
## values stay as they are; the original is kept on the params for a restart of the same track.
# original = The games gameplay settings object
# settings = The mods gameplay settings object
func _set_performance(track) -> void:
	var params = track.get("params") if track != null else null
	if params == null or params.get("is_multiplayer") or track.get("is_time_trial") or not params.get("gameplay_settings") is Object:
		return
	if not params.has_meta("car_switcher_gameplay"):
		params.set_meta("car_switcher_gameplay", params.gameplay_settings)
	var original: Object = params.get_meta("car_switcher_gameplay")
	var values = _performance.get(_field_class.to_lower()) # _performance: settings.cfg, _field_class: quick race popup
	params.remove_meta("car_switcher_gravity")
	params.remove_meta("car_switcher_no_drs")
	params.remove_meta("car_switcher_no_ers")
	params.remove_meta("car_switcher_performance")
	if not values is Dictionary:
		params.gameplay_settings = original
		return
	var settings: Object = original.get_script().new()
	settings.load_data(original.get_save_data())
	for key in values:
		if key == "gravity":
			params.set_meta("car_switcher_gravity", float(values[key]))  # read by car_gravity.gd
		elif key == "drs" or key == "ers":
			if not values[key]:
				params.set_meta("car_switcher_no_" + key, true)  # read by car_spin.gd
		elif settings.get(key) is float:
			settings.set(key, float(values[key]))
		else:
			push_error("[CarSwitcher] settings.cfg [performance]: no gameplay setting " + str(key))
	params.gameplay_settings = settings
	params.set_meta("car_switcher_performance", true)  # read by car_spin.gd: wheelspin / grip cost follow the engine power


func _player_or_random() -> String:
	return _player_type if _player_type != "" else _random_type()


## Deals cars from a shuffled bag of the field, so a grid repeats a car only once all have been used.
## A set player car is left out of the first round (unless it is the only car).
func _random_type() -> String:
	if _field.is_empty():
		return DEFAULT_CAR
	if _bag.is_empty():
		_bag = _field.duplicate()
		_bag.shuffle()
		if _bag_first and _player_type != "" and _bag.size() > 1:
			_bag.erase(_player_type)
		_bag_first = false
	return _bag.pop_back()


# --- Settings and the cars on disk (read once; edits apply at the next game start) ---

func _read_settings() -> void:
	var settings := ConfigFile.new()
	settings.load(_dir.path_join("settings.cfg"))
	for team_name in _section_keys(settings, "teams"):
		_teams[team_name.to_lower()] = str(settings.get_value("teams", team_name)).strip_edges()
	for car_class in _section_keys(settings, "performance"):
		_performance[car_class.to_lower()] = settings.get_value("performance", car_class)


func _section_keys(settings: ConfigFile, section: String) -> PackedStringArray:
	return settings.get_section_keys(section) if settings.has_section(section) else PackedStringArray()


## Every built car (folder with a car.glb): its name and classes (car.cfg classes=, a list or one string).
func _scan_cars() -> void:
	var cars_dir := _dir.path_join("cars")
	for type in DirAccess.get_directories_at(cars_dir):
		if not FileAccess.file_exists(cars_dir.path_join(type).path_join("car.glb")):
			continue
		var car := ConfigFile.new()
		car.load(cars_dir.path_join(type).path_join("car.cfg"))
		_names[type] = str(car.get_value("car", "name", type))
		var classes = car.get_value("car", "classes", [])
		for name in (classes if classes is Array else [classes]):
			name = str(name).strip_edges()
			if name != "":
				_classes.get_or_add(name.to_lower(), {"name": name, "cars": []}).cars.append(type)
	for car_class in _classes.values():
		car_class.cars.sort_custom(func(a, b): return _names[a].naturalnocasecmp_to(_names[b]) < 0)


## The field = the class's cars ("" or an unknown class: none). The player car is kept only if it is in it.
func _set_class(car_class: String) -> void:
	var known: Dictionary = _classes.get(car_class.to_lower(), {"name": "", "cars": []})
	_field_class = known.name
	_field = known.cars
	if not _player_type in _field:
		_player_type = ""


# --- Quick race popup: Class and Your Car dropdowns under "Laps" ---

## Caught in node_added: the popup's nodes exist but aren't ready yet, so the race settings group's
## _ready() wires the new rows' descriptions like its own. The choice applies when Start race is pressed
## (the form's confirmed signal; the game builds the track after it, asynchronously).
func _add_race_rows(quick_race: Node) -> void:
	var laps := quick_race.find_child("LapCountSpin", true, false)
	var form = quick_race.get("form")
	if laps == null or form == null or not form.has_signal("confirmed"):
		push_error("[CarSwitcher] quick race popup changed (no LapCountSpin / form.confirmed): no car dropdowns")
		return
	form.confirmed.connect(func(_config):
		_player_type = _chosen_player
		_set_class(_chosen_class))
	var class_option := _add_race_row(laps.get_parent(), "Class",
			"Sets the cars used for this race. Some classes have different car performance.")
	var car_option := _add_race_row(class_option.get_parent(), "Your Car",
			"Select your car. Random assigns a car from the class.")
	_add_option(class_option, "None", "")
	var class_names: Array = _classes.values().map(func(car_class): return car_class.name)
	class_names.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	for name in class_names:
		_add_option(class_option, name, name, name == _chosen_class)
	_fill_cars(car_option)
	class_option.item_selected.connect(func(index: int):
		_chosen_class = class_option.get_item_metadata(index)
		_fill_cars(car_option))
	car_option.item_selected.connect(func(index: int):
		_chosen_player = car_option.get_item_metadata(index))


## A row from the game's own settings row + dropdown scenes, styled like the Weather row, added after `after`.
func _add_race_row(after: Node, text: String, description: String) -> OptionButton:
	var row = load("res://ui/ui_settings/ui_settings_item/ui_settings_item.tscn").instantiate()
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HeaderSmall"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var option = load("res://ui/ui_option_button/ui_option_button.tscn").instantiate()
	option.custom_minimum_size = Vector2(200, 38)
	option.size_flags_horizontal = Control.SIZE_FILL
	option.clip_text = true
	option.fit_to_longest_item = false
	option.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	option.set("shape", 3)
	row.add_child(label)
	row.add_child(option)
	row.set("description_text", description)
	row.set("label", label)
	row.set("input", option)
	after.add_sibling(row)
	row.owner = after.owner  # the settings group finds its rows with find_children(), which only returns owned nodes
	return option


## Random + the chosen class's cars by name (only Random for class None). A chosen car not in it -> Random.
func _fill_cars(car_option: OptionButton) -> void:
	var cars: Array = _classes.get(_chosen_class.to_lower(), {"cars": []}).cars
	if not _chosen_player in cars:
		_chosen_player = ""
	car_option.clear()
	_add_option(car_option, "Random", "")
	for type in cars:
		_add_option(car_option, _names[type], type, type == _chosen_player)


func _add_option(option: OptionButton, text: String, value: String, selected := false) -> void:
	option.add_item(text)
	option.set_item_metadata(option.item_count - 1, value)
	if selected:
		option.select(option.item_count - 1)


# --- Loading a car ---

## The car's parts (empty if unusable). Loaded once per type.
func _load_car(type: String) -> Dictionary:
	if type == DEFAULT_CAR:
		return {}
	if _cars.has(type):
		return _cars[type]
	_cars[type] = {}
	var parts := _read_parts(_dir.path_join("cars").path_join(type).path_join("car.glb"))
	if parts.is_empty():
		return {}
	_add_mipmaps(parts)
	_cars[type] = parts
	return parts

## The glb's top-level nodes: { name: {"position", "mesh" (or null)} }, empty if a required part is missing.
func _read_parts(path: String) -> Dictionary:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state) != OK:
		push_error("[CarSwitcher] could not read " + path)
		return {}
	var scene := document.generate_scene(state)
	var parts := {}
	for node in scene.get_children():
		if node is Node3D:
			var mesh: Mesh = node.mesh if node is MeshInstance3D else null
			parts[str(node.name)] = {"position": node.position, "mesh": mesh}
	scene.free()
	for part_name in REQUIRED_PARTS:
		if not parts.has(part_name) or parts[part_name].mesh == null:
			push_error("[CarSwitcher] " + path + " has no " + part_name + " mesh")
			return {}
	var material = parts.Chassis.mesh.surface_get_material(0)
	if not (material is BaseMaterial3D and material.albedo_texture != null):
		push_error("[CarSwitcher] " + path + ": the Chassis has no texture")
		return {}
	return parts

## Textures loaded from a glb at run time have no mipmaps: far away they would shimmer and sparkle.
## Materials share the atlas, so each texture is copied once.
func _add_mipmaps(parts: Dictionary) -> void:
	var mipmapped := {}  # original texture -> its copy with mipmaps
	for part in parts.values():
		var mesh: Mesh = part.mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var material = mesh.surface_get_material(surface)
			if not material is BaseMaterial3D:
				continue
			for property in ["albedo_texture", "roughness_texture", "metallic_texture"]:  # the last two: surface atlas
				var texture: Texture2D = material.get(property)
				if texture == null:
					continue
				if not mipmapped.has(texture):
					var image := texture.get_image()
					if image != null and not image.has_mipmaps():
						image.generate_mipmaps()
						mipmapped[texture] = ImageTexture.create_from_image(image)
					else:
						mipmapped[texture] = texture
				material.set(property, mipmapped[texture])

# --- Swapping a model ---

func _apply(model: Node3D, parts: Dictionary) -> void:
	var sprung := model.find_child("SprungMass", false, false) as Node3D
	var material: BaseMaterial3D = parts.Chassis.mesh.surface_get_material(0)
	var texture := material.albedo_texture
	if sprung == null or not _patch_materials(model, texture, material.roughness_texture):
		push_error("[CarSwitcher] the game's car model changed in an update, keeping the game's car")
		return
	_patch_outline(model, texture)
	_hide_game_parts(model, sprung, parts)
	var wheels := _place_parts(model, sprung, parts)
	_swapped.append({"model": model, "wheels": wheels, "last_position": null})


## Gives the chassis and wing materials the patched shaders and the car's texture. False (nothing
## changed) if a shader can't be patched.
func _patch_materials(model: Node3D, texture: Texture2D, surface: Texture2D) -> bool:
	var materials := [model.get("mat"), model.get("damage_mat")]  # chassis, wings
	if not materials.all(func(material): return material is ShaderMaterial):
		return false
	var shaders := materials.map(func(material): return _patched(material.get("shader"), SHADER_PATCHES, PAINT_PATCHES))
	if shaders.has(null):
		return false
	for i in materials.size():
		materials[i].shader = shaders[i]
		materials[i].set_shader_parameter("car_texture", texture)
		materials[i].set_shader_parameter("car_surface", surface)
		materials[i].set_shader_parameter("car_surface_on", surface != null)
	return true


## The highlight outline with OUTLINE_PATCHES (nothing changed if a line is missing).
func _patch_outline(model: Node3D, texture: Texture2D) -> void:
	var outline = model.get("highlight_mat")
	var shader := _patched(outline.shader, OUTLINE_PATCHES) if outline is ShaderMaterial else null
	if shader != null:
		outline.shader = shader
		outline.set_shader_parameter("car_texture", texture)


## Hides everything on the game's body that the new car doesn't replace (suspension, steering wheel,
## number) and the driver.
func _hide_game_parts(model: Node3D, sprung: Node3D, parts: Dictionary) -> void:
	for child in sprung.get_children():
		if child is MeshInstance3D and not parts.has(str(child.name)):
			child.visible = false
	var driver = model.get("driver")
	if driver is Node3D:
		driver.visible = false
		model.set("driver", null)  # the game would show the driver again when leaving the onboard camera


## Moves (and, for meshes, replaces) the game's same-named parts. Returns the wheels to spin: [[node, radius]].
func _place_parts(model: Node3D, sprung: Node3D, parts: Dictionary) -> Array:
	var wheels := []
	for part_name in parts:
		var target := model.find_child(part_name, true, false) as Node3D
		if target == null:
			continue
		var part: Dictionary = parts[part_name]
		var position: Vector3 = part.position  # model space
		if target.get_parent() == sprung:
			position = sprung.transform.affine_inverse() * position
		if part.mesh == null or not target is MeshInstance3D:
			target.position = position
			continue
		target.mesh = part.mesh
		target.transform = Transform3D(Basis.IDENTITY, position)
		if not part_name in WHEELS:
			target.set_instance_shader_parameter("car_cut", 1.0)  # outline: skip cut-out texels
		var height: float = part.mesh.get_aabb().size.y
		if part_name in WHEELS and height > 0.1:
			wheels.append([target, height / 2.0])
	_add_glass(model, parts)
	return wheels


## The car's glass (glb node "Glass", its own transparent material: the car shaders can only cut out)
## as a child of the Chassis, so it leans with the body.
func _add_glass(model: Node3D, parts: Dictionary) -> void:
	var chassis := model.find_child("Chassis", true, false) as Node3D
	var old := chassis.get_node_or_null(GLASS_NODE) if chassis != null else null
	if old != null:
		old.free()
	if chassis == null or not parts.has("Glass") or parts.Glass.mesh == null:
		return
	var glass := MeshInstance3D.new()
	glass.name = GLASS_NODE
	glass.mesh = parts.Glass.mesh
	glass.position = parts.Glass.position - parts.Chassis.position
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material = glass.mesh.surface_get_material(0)
	if material is BaseMaterial3D:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA  # the glTF import's depth pre-pass hid things behind
	chassis.add_child(glass)


## The game's shader with the `required` patches (null if a line is missing) and the `optional` ones whose
## lines are there. Cached per game shader; one of our patched shaders is returned as it is.
func _patched(original, required: Dictionary, optional := {}) -> Shader:
	if not original is Shader:
		return null
	if original in _shaders.values():
		return original
	if not _shaders.has(original):
		var code: String = original.code
		var shader: Shader = null
		if required.keys().all(func(line): return line in code):
			for line in required:
				code = code.replace(line, required[line])
			for line in optional:
				code = code.replace(line, optional[line])
			shader = Shader.new()
			shader.code = code
		_shaders[original] = shader
	return _shaders[original]