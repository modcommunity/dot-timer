class_name DotTimerCheckpoints
extends RefCounted

## Practice mode: save where you are, teleport back to it, and keep trying the bit you cannot do.
## Stores state, not a node; what to do with a restored checkpoint is the game's. Restoring taints the run via [method DotTimer.note_checkpoint_used].

# No log channel: one player's practice state. Saving and restoring are keypresses, a
# line per press is noise, and the one consequence that matters -- the run is tainted --
# belongs to DotTimer, which is told.

## A saved checkpoint was added, replaced or removed.
signal changed(count: int, index: int)

## Everything a player needs putting back.
class Checkpoint extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var pitch: float = 0.0

	## Whether the player was on the ground when it was saved.
	## Restored, because a mid-air checkpoint restored as grounded gives a free landing and picks the next tick's acceleration.
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
## Optional: a game with no timer still wants practice teleports.
var timer: DotTimer = null

## The saved checkpoints, oldest first.
var saved: Array[Checkpoint] = []

## Which one [method load_current] returns. Moved by [method previous] / [method next].
var index: int = 0

## Most checkpoints one player may hold.
## Bounded and lower than it looks: past about ten, cycling to the one you want takes longer than the section.
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
## Saving does not taint the run, restoring does: the shortcut is the teleport, not the habit of pressing save.
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
## Calling this taints the run, because it is what a teleport key calls; to only LOOK, use [method peek].
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


## Throws them all away. Does not un-taint the run: the flag is sticky, or clearing checkpoints would launder a segmented run.
func clear() -> void:
	saved.clear()
	index = 0
	changed.emit(0, 0)


## Serialises the set, so a server can keep it across a map change or a reconnect.
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
