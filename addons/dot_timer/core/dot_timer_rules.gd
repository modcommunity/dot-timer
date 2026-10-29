class_name DotTimerRules
extends RefCounted

## The velocity rules a timer imposes on a player, as pure functions; call them from the movement loop after the timer has ticked.
## Nothing here allocates or reads a clock.

## Caps horizontal speed, leaving the vertical component alone. 0 = no limit.
## Horizontal only: clamping vertical too would cancel a fall into the start area and leave the player hanging.
static func clamp_prespeed(velocity: Vector3, limit: float) -> Vector3:
	if limit <= 0.0:
		return velocity

	var horizontal := Vector2(velocity.x, velocity.z)
	var speed := horizontal.length()

	if speed <= limit or speed <= 0.0:
		return velocity

	var scale := limit / speed

	return Vector3(velocity.x * scale, velocity.y, velocity.z * scale)


## The same for a game whose plane is XY rather than XZ.
static func clamp_prespeed_2d(velocity: Vector3, limit: float) -> Vector3:
	if limit <= 0.0:
		return velocity

	var planar := Vector2(velocity.x, velocity.y)
	var speed := planar.length()

	if speed <= limit or speed <= 0.0:
		return velocity

	var scale := limit / speed

	return Vector3(velocity.x * scale, velocity.y * scale, velocity.z)


## Applies a [constant DotTimerZone.Kind.SPEED_LIMIT] zone, if one is in force.
##
## [param zone] is what [method DotTimer.effect] returned, or null.
static func apply_speed_limit(velocity: Vector3, zone: DotTimerZone) -> Vector3:
	if zone == null or zone.number <= 0.0:
		return velocity

	return clamp_prespeed(velocity, zone.number)


## Applies a [constant DotTimerZone.Kind.PUSH] zone for one tick.
## An acceleration, so it composes with friction and gravity; a velocity assignment would cancel a fall through it.
static func apply_push(
	velocity: Vector3, zone: DotTimerZone, delta: float
) -> Vector3:
	if zone == null:
		return velocity

	return velocity + zone.direction * delta


## Whether a run should be allowed to start given how the player is moving.
## [param air_start] comes from the style: an air start is how speed is built outside the start zone.
static func may_start(grounded: bool, alive: bool, air_start: bool) -> bool:
	return alive and (grounded or air_start)
