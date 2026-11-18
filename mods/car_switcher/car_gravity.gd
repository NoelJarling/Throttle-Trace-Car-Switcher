extends "res://cars/physics/car_speed.gd"

const GAME_GRAVITY := 50.0

func _drive(delta: float) -> void:
	var params = car.track.params if car.track != null else null
	if params != null and params.has_meta("car_switcher_gravity"):
		# Before super: after it, the game's resistance cap left a small uphill creep at a standstill
		var factor: float = float(params.get_meta("car_switcher_gravity")) / GAME_GRAVITY - 1.0
		car.speed += factor * CarPerformance.get_slope_accel(car.global_transform.basis) * delta
	super(delta)
