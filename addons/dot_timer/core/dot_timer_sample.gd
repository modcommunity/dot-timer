class_name DotTimerSample
extends RefCounted

## One tick of a player, as the timer sees them.
##
## [b]This class is why dot-timer depends on nothing but dot-core.[/b] The timer needs
## a position, a velocity and whether the player is on the ground. It does not need to
## know that they came from a [code]DotFpsState[/code], or from a 2D body, or from a
## replay being played back, or from a bot — and if it asked for any of those by name,
## the addon would not compile in a project without them.
##
## So the host fills one of these in each tick. Three lines for a first-person game:
##
## [codeblock]
## sample.position = controller.state.position
## sample.velocity = controller.state.velocity
## sample.grounded = controller.state.is_grounded()
## [/codeblock]
##
## and for a 2D game, the same with [code]Vector3(pos.x, pos.y, 0)[/code] against
## zones that were flattened with [method DotTimerZone.flatten_for_2d].
##
## [b]Reused, not allocated per tick.[/b] A server running thirty players at 128 Hz
## would otherwise allocate nearly four thousand of these a second, all of them
## garbage. [DotTimerManager] keeps one per player.

## Where the player is. For a first-person controller this is their feet.
##
## [b]Whatever it is, it must be the same point every tick and the same point the
## zones were drawn against.[/b] Mixing feet and eye position between the editor and
## the runtime moves every zone boundary by the player's height, which reads as the
## zones being in the wrong place rather than as a units mistake.
var position: Vector3 = Vector3.ZERO

## Where they were on the previous tick.
##
## Kept by the timer, not by the host: the sub-tick crossing fraction is computed from
## the segment between two ticks, and a host that forgot to update this would produce
## times that are subtly and unfixably wrong.
var previous_position: Vector3 = Vector3.ZERO

var velocity: Vector3 = Vector3.ZERO

var grounded: bool = false

## Whether the player is alive and should be timed at all.
##
## A dead or spectating player still has a position, and without this the timer keeps
## running while they watch somebody else.
var alive: bool = true

## The buttons held, in the host's own vocabulary. Passed through to zone effects.
var buttons: int = 0

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
