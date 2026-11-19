extends "res://cars/physics/car_speed.gd"
## The class's gravity on slopes (created by car_spin.gd only when the race's params have car_switcher_gravity).

const GAME_GRAVITY := 50.0

var _factor := 0.0  # extra slope acceleration on top of the game's: class gravity / the game's - 1


func _init(_car: Car) -> void:
	super(_car)
	_factor = float(_car.track.params.get_meta("car_switcher_gravity", GAME_GRAVITY)) / GAME_GRAVITY - 1.0


func _drive(delta: float) -> void:
	# Before super: after it, the game's resistance cap left a small uphill creep at a standstill
	car.speed += _factor * CarPerformance.get_slope_accel(car.global_transform.basis) * delta
	super(delta)
