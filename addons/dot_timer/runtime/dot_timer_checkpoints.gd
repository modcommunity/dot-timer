class_name DotTimerCheckpoints
extends RefCounted

## Practice mode: save where you are, teleport back to it, and keep trying the bit
## you cannot do.
##
## [b]After the timer itself this is the most-used feature on a surf or bhop
## server.[/b] A four-minute map with one hard section is four minutes of walking
## back per attempt without it, and every timer in the genre has had `+cp` / `+tp`
## bound to a key for fifteen years. Shipping a timer without it is shipping a timer
## people will not practise on.
##
## [codeblock]
## checkpoints.save(position, velocity, yaw, pitch)   # +cp
## var cp := checkpoints.load_current()               # +tp
## if cp != null:
##     player.teleport_to(cp)
## [/codeblock]
##
## [b]Using one taints the run, and the taint is sticky.[/b] A run in which the player
## restored a saved position is not a run — [method DotTimer.note_checkpoint_used]
## either flags it or abandons it, depending on the style — and clearing the flag when
## they stop would let anybody file a record for the last thirty seconds of a map.
## This class calls that for you, because a game that had to remember to is a game
## that will forget on one of its code paths.
##
## [b]It stores state, not a node.[/b] The same reasoning as [DotTimerSample]: a
## checkpoint is a position, a velocity and a view, and what to do with them is the
## game's — restoring into a [code]DotFpsState[/code], a 2D body or a replay scrubber
## are three different things and none of them belongs here.

const CHANNEL := "timer.checkpoints"

## A saved checkpoint was added, replaced or removed.
signal changed(count: int, index: int)

## Everything a player needs putting back.
class Checkpoint extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var pitch: float = 0.0

	## Whether the player was on the ground when it was saved.
	##
	## Restored, because a checkpoint taken mid-air and restored as grounded gives a
	## free landing — and on a surf map "am I on the ground" decides which
	## acceleration runs on the very next tick.
	var grounded: bool = false

	## Whether they were crouched.
	var crouched: bool = false

	## The run's tick count when it was taken. For a HUD showing where in the run
	## a checkpoint is, and for nothing the simulation reads.
	var run_ticks: int = 0

	## Anything the game wants to restore with it.
	var extra: Dictionary = {}

	func duplicate_checkpoint() -> Checkpoint:
		var out := Checkpoint.new()
		out.position = position
		out.velocity = velocity
		out.yaw = yaw
		out.pitch = pitch
		out.grounded = grounded
		out.crouched = crouched
		out.run_ticks = run_ticks
		out.extra = extra.duplicate(true)
		return out

	func to_dictionary() -> Dictionary:
		return {
			"position": [position.x, position.y, position.z],
			"velocity": [velocity.x, velocity.y, velocity.z],
			"yaw": yaw,
			"pitch": pitch,
			"grounded": grounded,
			"crouched": crouched,
			"run_ticks": run_ticks,
			"extra": extra.duplicate(true),
		}

	func _to_string() -> String:
		return "Checkpoint(%.1f, %.1f, %.1f)" % [
			position.x, position.y, position.z
		]

## The timer this belongs to. Told whenever a checkpoint is restored.
##
## Optional: a game with no timer still wants practice teleports, and a class that
## required one could not serve it.
var timer: DotTimer = null

## The saved checkpoints, oldest first.
var saved: Array[Checkpoint] = []

## Which one [method load_current] returns. Moved by [method previous] / [method next].
var index: int = 0

## Most checkpoints one player may hold.
##
## [b]Bounded, and lower than it looks.[/b] Thirty is far more than anybody navigates
## by hand — past about ten, cycling to the one you want takes longer than the section
## you saved it for — and a player who holds the key spends nothing but memory
## otherwise.
var limit: int = 30

## Whether saving is allowed at all. A ranked style may turn this off entirely.
var enabled: bool = true


static func of(p_timer: DotTimer) -> DotTimerCheckpoints:
	var checkpoints := DotTimerCheckpoints.new()
	checkpoints.timer = p_timer
	return checkpoints


func count() -> int:
	return saved.size()


func is_empty() -> bool:
	return saved.is_empty()


## Saves the player's current state as a new checkpoint.
##
## [b]Saving does not taint the run; restoring does.[/b] Pressing the save key on the
## way past a section costs nothing and is what a player does out of habit — punishing
## it would mean punishing the habit rather than the shortcut, and the shortcut is
## the teleport.
func save(
	position: Vector3,
	velocity: Vector3,
	yaw: float = 0.0,
	pitch: float = 0.0,
	grounded: bool = false,
	crouched: bool = false,
	extra: Dictionary = {}
) -> DotResult:
	if not enabled:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "Checkpoints are off on this style."
		)

	var checkpoint := Checkpoint.new()
	checkpoint.position = position
	checkpoint.velocity = velocity
	checkpoint.yaw = yaw
	checkpoint.pitch = pitch
	checkpoint.grounded = grounded
	checkpoint.crouched = crouched
	checkpoint.extra = extra.duplicate(true)

	if timer != null:
		checkpoint.run_ticks = timer.run.ticks

	saved.append(checkpoint)

	# The OLDEST goes when the list is full, and the cursor moves with it so it keeps
	# pointing at the checkpoint it was pointing at. Dropping the newest would throw
	# away the one just taken, which is never what the key press meant.
	while saved.size() > limit:
		saved.pop_front()
		index = maxi(index - 1, 0)

	index = saved.size() - 1

	changed.emit(saved.size(), index)

	return DotResult.success(checkpoint)


## The checkpoint at [member index], or null.
##
## [b]Calling this is what taints the run[/b], because it is what a teleport key
## calls — the game restores whatever comes back. A caller that only wants to LOOK at
## a checkpoint uses [method peek].
func load_current() -> Checkpoint:
	var checkpoint := peek()

	if checkpoint == null:
		return null

	if timer != null:
		# Flags the run, or abandons it on a style that forbids checkpoints
		# altogether — which is the honest thing, because continuing to time a run
		# that can never be filed wastes the player's next four minutes.
		timer.note_checkpoint_used()

	return checkpoint


## The checkpoint at [member index] without touching the run.
func peek() -> Checkpoint:
	if saved.is_empty():
		return null

	index = clampi(index, 0, saved.size() - 1)

	return saved[index]


## Removes the checkpoint at [member index].
func remove_current() -> bool:
	if saved.is_empty():
		return false

	saved.remove_at(clampi(index, 0, saved.size() - 1))
	index = clampi(index, 0, maxi(saved.size() - 1, 0))

	changed.emit(saved.size(), index)

	return true


func previous() -> Checkpoint:
	if saved.is_empty():
		return null

	index = posmod(index - 1, saved.size())
	changed.emit(saved.size(), index)

	return saved[index]


func next() -> Checkpoint:
	if saved.is_empty():
		return null

	index = posmod(index + 1, saved.size())
	changed.emit(saved.size(), index)

	return saved[index]


## Throws them all away.
##
## [b]Does not un-taint the run.[/b] The flag is sticky for the whole attempt, and a
## player who could clear it by clearing their checkpoints would have a one-keypress
## route to filing a segmented run as a clean one.
func clear() -> void:
	saved.clear()
	index = 0
	changed.emit(0, 0)


## Serialises the set, so a server can keep it across a map change or a reconnect.
##
## Worth keeping: on a hard map somebody spends an evening building a set of
## checkpoints, and losing them to a map vote is the difference between practising
## and giving up.
func to_dictionary() -> Dictionary:
	var list: Array = []

	for checkpoint in saved:
		list.append(checkpoint.to_dictionary())

	return {"index": index, "checkpoints": list}


static func from_dictionary(data: Dictionary) -> DotTimerCheckpoints:
	var out := DotTimerCheckpoints.new()

	var list_value: Variant = data.get("checkpoints", [])

	if list_value is Array:
		for entry in (list_value as Array):
			if not (entry is Dictionary):
				continue

			var row: Dictionary = entry
			var checkpoint := Checkpoint.new()

			checkpoint.position = _vector(row.get("position"))
			checkpoint.velocity = _vector(row.get("velocity"))
			checkpoint.yaw = float(row.get("yaw", 0.0))
			checkpoint.pitch = float(row.get("pitch", 0.0))
			checkpoint.grounded = bool(row.get("grounded", false))
			checkpoint.crouched = bool(row.get("crouched", false))
			checkpoint.run_ticks = int(row.get("run_ticks", 0))

			var extra_value: Variant = row.get("extra", {})
			checkpoint.extra = (
				(extra_value as Dictionary).duplicate(true)
				if extra_value is Dictionary else {}
			)

			out.saved.append(checkpoint)

	out.index = clampi(
		int(data.get("index", 0)), 0, maxi(out.saved.size() - 1, 0)
	)

	return out


static func _vector(value: Variant) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func describe() -> Dictionary:
	return {
		"saved": saved.size(),
		"index": index,
		"enabled": enabled,
		"limit": limit,
	}


func _to_string() -> String:
	return "DotTimerCheckpoints(%d/%d)" % [index + 1, saved.size()]
