class_name DotTimerRules
extends RefCounted

## The velocity rules a timer imposes on a player, as pure functions.
##
## [b]Pure, static and outside the timer, because they run inside the simulation.[/b]
## Clamping a player's speed at the start line changes where they end up, so it has to
## happen on the client and the server identically, on the same tick, before the move
## — which is the movement loop's business, not the timer's. The timer decides
## [i]that[/i] a limit applies (it owns the zones); these decide what the limit does.
##
## [codeblock]
## # in the movement loop, after the timer has ticked
## if timer.in_zone(DotTimerZone.Kind.START):   # NOT is_inside: that is effects only
##     velocity = DotTimerRules.clamp_prespeed(velocity, style.prespeed_limit)
## [/codeblock]
##
## Nothing here allocates and nothing reads a clock.

## Caps horizontal speed, leaving the vertical component alone. 0 = no limit.
##
## [b]Horizontal only, and that is the point.[/b] The rule exists to stop a player
## building speed in the start zone and diving through the line; clamping their
## vertical velocity as well would also cancel their fall, so a player who dropped
## into the start area would hang in the air. Every timer in this genre gets this
## right and it is the first thing a re-implementation gets wrong.
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
##
## An acceleration rather than a velocity, so it composes with friction and gravity
## instead of fighting them — the same choice [code]DotFpsSurface.push[/code] makes,
## and for the same reason: a push that assigned a velocity would cancel a player's
## fall through it.
static func apply_push(
	velocity: Vector3, zone: DotTimerZone, delta: float
) -> Vector3:
	if zone == null:
		return velocity

	return velocity + zone.direction * delta


## Whether a run should be allowed to start given how the player is moving.
##
## [param air_start] comes from the style. A run started in mid-air is how a player
## builds speed outside the start zone and dives through it, so most styles refuse it.
static func may_start(grounded: bool, alive: bool, air_start: bool) -> bool:
	return alive and (grounded or air_start)
