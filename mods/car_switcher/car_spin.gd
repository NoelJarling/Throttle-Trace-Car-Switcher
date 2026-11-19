extends "res://cars/car.gd"
## Wheelspin that knows the engine power (installed by mod.gd through ModLoader.extend_script).
## Everything here applies only in races with class performance values (params metas set by mod.gd);
## otherwise the game's own behaviour is unchanged.

const GRAVITY_SCRIPT := "user://mods/car_switcher/car_gravity.gd"
const DEFAULT_ENGINE_POWER := 0.75

var _power_scale := 1.0  # class engine power / the game's default; 1 = the game's own spin limit and grip cost
var _no_drs := false
var _no_ers := false


func _ready() -> void:
	var params = track.params
	if params.has_meta("car_switcher_performance"):
		_power_scale = params.gameplay_settings.engine_power / DEFAULT_ENGINE_POWER
		# The spin limit follows the engine power: wraps the game's formula, so wheelspin, traction control,
		# AI pedals, the launch limit and tyre load (drive_demand) all read the scaled value
		var game_limit: Callable = _raw_max_throttle_before_wheel_spin.getter
		_raw_max_throttle_before_wheel_spin.getter = func(): return game_limit.call() / maxf(_power_scale, 0.01)
	if params.has_meta("car_switcher_gravity"):
		var gravity_speed = load(GRAVITY_SCRIPT) if ResourceLoader.exists(GRAVITY_SCRIPT) else null
		if gravity_speed != null and gravity_speed.can_instantiate():
			car_speed = gravity_speed.new(self)
		else:
			push_error("[CarSwitcher] can't load " + GRAVITY_SCRIPT + ": hills use the game's gravity")
	_no_drs = params.has_meta("car_switcher_no_drs")
	_no_ers = params.has_meta("car_switcher_no_ers")
	super()


# Corner exit grip cost scaled to the engine power (like the spin limit)
func get_throttle_grip_cost() -> float:
	return super() * _power_scale


func process_step(delta: float):
	_no_drs_ers()  # before: DRS start points open DRS between steps
	super(delta)
	_no_drs_ers()  # after: the AI / player set the ERS mode during the step


func _no_drs_ers() -> void:
	if _no_drs:
		drs_state = "idle"
	if _no_ers:
		ers.mode = CarErs.Mode.Off
		ers.battery = 0.0  # empty: no "plenty of battery" radio calls
