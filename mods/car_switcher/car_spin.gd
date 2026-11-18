extends "res://cars/car.gd"
## Wheelspin that knows the engine power (installed by mod.gd through ModLoader.extend_script).
## Everything here applies only in races with class performance values (params metas set by mod.gd);
## otherwise the game's own behaviour is unchanged.

const GRAVITY_SCRIPT := "user://mods/car_switcher/car_gravity.gd"
const DEFAULT_ENGINE_POWER := 0.75

# Load the gravity script
func _ready() -> void:
	var gravity_speed = load(GRAVITY_SCRIPT) if ResourceLoader.exists(GRAVITY_SCRIPT) else null
	if gravity_speed != null and gravity_speed.can_instantiate():
		car_speed = gravity_speed.new(self)
	else:
		push_error("[CarSwitcher] can't load " + GRAVITY_SCRIPT + ": hills use the game's gravity")
	super()

# Scale corner exit grip to the engine power (like the spin limit below)
func get_throttle_grip_cost() -> float:
	return super() * _power() / DEFAULT_ENGINE_POWER

## The class's engine power; DEFAULT_ENGINE_POWER (= the game's own spin limit and grip cost) without class performance.
func _power() -> float:
	var params = track.params if track != null else null
	if params == null or not params.has_meta("car_switcher_performance"):
		return DEFAULT_ENGINE_POWER
	return params.gameplay_settings.engine_power

# Scale the spin limit from the throttle to the car's engine power
func _spin_limit() -> float:
	var limit: float = _raw_max_throttle_before_wheel_spin.get_value() * DEFAULT_ENGINE_POWER / maxf(_power(), 0.01)
	return clampf(limit, 0.0, 1.0)

# Wheelspin on throttle / acceleration
func get_wheel_spin_at_throttle(throttle: float) -> float:
	var overshoot = clampf((throttle - _spin_limit()) / WHEEL_SPIN_THROTTLE_RANGE, 0.0, 1.0)
	return pow(overshoot, WHEEL_SPIN_ONSET_EXPONENT)

# Reverse wheelspin at throttle function for the AI cars
func get_throttle_for_wheel_spin(spin: float) -> float:
	var overshoot = pow(clampf(spin, 0.0, 1.0), 1.0 / WHEEL_SPIN_ONSET_EXPONENT)
	return _spin_limit() + (overshoot * WHEEL_SPIN_THROTTLE_RANGE)

# Update the ERS and DRS settings every car process step
func process_step(delta: float):
	_no_drs_ers()  # before: DRS start points open DRS between steps
	super(delta)
	_no_drs_ers()  # after: the AI / player set the ERS mode during the step


func _no_drs_ers() -> void:
	var params = track.params if track != null else null
	if params == null:
		return
	if params.has_meta("car_switcher_no_drs"):
		drs_state = "idle"
	if params.has_meta("car_switcher_no_ers"):
		ers.mode = CarErs.Mode.Off
		ers.battery = 0.0  # empty: no "plenty of battery" radio calls