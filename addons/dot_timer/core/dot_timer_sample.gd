class_name DotTimerSample
extends RefCounted

## One tick of a player, as the timer sees them: position, velocity, grounded. The host fills one in each tick and reuses it.
## This class is why dot-timer depends on nothing but dot-core; the timer never names a controller type.

## Where the player is; for a first-person controller, their feet.
## Must be the same point every tick and the one the zones were drawn against, or every zone boundary shifts by the player's height.
var position: Vector3 = Vector3.ZERO

## Where they were on the previous tick, kept by the timer.
## The sub-tick crossing fraction comes from the segment between two ticks; a host maintaining this would get times subtly wrong.
var previous_position: Vector3 = Vector3.ZERO

var velocity: Vector3 = Vector3.ZERO

var grounded: bool = false

## Whether the player is alive and should be timed at all.
## A dead or spectating player still has a position and would otherwise keep the clock running.
var alive: bool = true

## The buttons held, in the host's own vocabulary. Passed through to zone effects.
var buttons: int = 0

## Whether the player is flying through walls. A run in progress stops the tick this is
## set: no clip is the one movement mode that makes every map trivial, and a run that
## merely recorded it would be one more flag a store has to remember to check.
var noclip: bool = false

## Anything else a game's own zone kinds need.
var extra: Dictionary = {}


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Horizontal speed for a 2D game, where the second axis is Y rather than Z.
func planar_speed_2d() -> float:
	return Vector2(velocity.x, velocity.y).length()


## How far the player moved since the previous tick.
func travelled() -> Vector3:
	return position - previous_position


func describe() -> Dictionary:
	return {
		"position": "(%.2f, %.2f, %.2f)" % [position.x, position.y, position.z],
		"speed": "%.2f m/s" % velocity.length(),
		"grounded": grounded,
		"alive": alive,
	}
