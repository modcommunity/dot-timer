class_name DotTimerPoints
extends RefCounted

## What a record is worth, and how a player's records add up to a ranking.
##
## [b]Three formulas, chosen by configuration, because the choice is the whole of a
## ranking system's politics and communities disagree about it.[/b] A ranking by raw
## time rewards whoever plays the easiest map; one by placement rewards whoever plays the
## emptiest. Each of these is a different compromise:
##
## - [constant Formula.CURVE] — the tier's worth, quadratic in the tier, scaled by how
##   close the run is to the record, never below a fifth for a clear. Improving always
##   pays and a first clear of a hard map pays well. [DotTimerStyle.points_for] is this
##   one, and it is the default because it is what every record filed so far was scored
##   with.
## - [constant Formula.TIERED] — linear in the tier plus a share of the record's own
##   length, scaled by closeness; bonuses count at a fixed fraction of a tier-one map.
##   Long maps are worth more than short ones of the same tier, which is the argument
##   for it.
## - [constant Formula.PLACEMENT] — placement on the board, not closeness: a record is
##   worth a tier- and population-dependent amount, the next nine a falling share of it,
##   everyone else a share by which slice of the board they are in, and every clear a
##   flat completion award by tier. Rewards being near the top of a crowded board, which
##   is the argument for it; it means every row on a board moves when anybody's does.
##
## [b]Every formula is recomputed for the whole board when its record changes[/b] — and
## for PLACEMENT on any change — because every row's worth depends on the record (or on
## everybody's place). Scoring once at filing and never again would leave a board whose
## points say the record is a time it no longer is. [DotTimerManager] does the re-score;
## this class only computes.
##
## [b]A player's total is a weighted sum[/b]: their records sorted best first, the
## [code]i[/code]-th multiplied by [code]weighting^i[/code]. At 0.975 the hundredth record
## is worth eight percent of the first, so a ranking reflects the best a player has done
## rather than how many easy maps they have cleared. 1.0 is a plain sum.

enum Formula {
	CURVE,
	TIERED,
	PLACEMENT,
}

var formula: Formula = Formula.CURVE

## TIERED: points per tier step.
var points_per_tier: float = 50.0

## TIERED: what a bonus is worth, as a fraction of a tier-one map.
var bonus_factor: float = 0.25

## Decay down a player's own list. See the class documentation.
var weighting: float = 0.975

## How many of a player's records count towards their total. 0 = all.
var weighting_limit: int = 0

## PLACEMENT: the share of the record's worth ranks 1..10 get.
const TOP_TEN := [1.0, 0.8, 0.75, 0.7, 0.65, 0.6, 0.55, 0.5, 0.45, 0.4]

## PLACEMENT: the five slices below the top ten, as fractions of the board's population.
## Each slice's lower bound is the board's population times this, plus the top ten.
const SLICES := [0.03125, 0.0625, 0.125, 0.25, 0.5]

## PLACEMENT: points for a clear, by tier 1..10 — whatever the time.
const COMPLETION := [25.0, 50.0, 100.0, 200.0, 400.0, 600.0, 800.0, 1000.0, 1200.0, 1400.0]

## PLACEMENT: a bonus's points by rank, not scaled by tier. Past the list, the last value.
const BONUS_LADDER := [
	250.0, 235.0, 220.0, 205.0, 190.0, 175.0, 160.0, 145.0, 130.0, 100.0,
	95.0, 90.0, 80.0, 70.0, 60.0, 50.0, 40.0, 30.0, 20.0, 10.0, 5.0,
]


static func formula_from_name(text: String) -> int:
	match text.strip_edges().to_lower():
		"curve", "":
			return Formula.CURVE
		"tiered", "tier":
			return Formula.TIERED
		"placement", "positional", "rank":
			return Formula.PLACEMENT
	return -1


static func formula_name(value: int) -> String:
	match value:
		Formula.TIERED:
			return "tiered"
		Formula.PLACEMENT:
			return "placement"
	return "curve"


## Whether a change to a board that did NOT change its record still moves other rows'
## points. True for PLACEMENT: one player moving up moves everybody they passed down.
func rescore_on_any_change() -> bool:
	return formula == Formula.PLACEMENT


## The points one record is worth.
##
## [param record_time] is the board's best (this run's own time if it is the record).
## [param rank] and [param finishers] are only read by PLACEMENT. [param multiplier] is
## the style's. A non-positive time is worth nothing, and so is a section record: the
## ranking is of whole runs.
func points_for(
	time: float,
	record_time: float,
	tier: int,
	track: int,
	multiplier: float,
	rank: int = 1,
	finishers: int = 1
) -> float:
	if time <= 0.0 or multiplier <= 0.0:
		return 0.0

	var t := clampi(tier, 1, 10)
	var best := record_time if record_time > 0.0 else time
	var closeness := clampf(best / time, 0.0, 1.0)

	match formula:
		Formula.TIERED:
			var effective := 1 if DotTimerTrack.is_bonus(track) else t
			var worth := (points_per_tier * float(effective) * 1.5 + best / 15.0) * closeness
			if DotTimerTrack.is_bonus(track):
				worth *= bonus_factor
			return worth * multiplier

		Formula.PLACEMENT:
			if DotTimerTrack.is_bonus(track):
				return float(BONUS_LADDER[clampi(rank, 1, BONUS_LADDER.size()) - 1]) * multiplier
			return (placement_points(t, rank, finishers) + COMPLETION[t - 1]) * multiplier

	# CURVE — DotTimerStyle.points_for's formula, kept identical so records already
	# scored with it do not move when the formula is merely restated here.
	var base := 25.0 * float(t) * float(t) / 10.0
	return base * (0.2 + 0.8 * closeness) * multiplier


## PLACEMENT: what rank [param rank] on a board of [param finishers] earns before the
## completion award.
static func placement_points(tier: int, rank: int, finishers: int) -> float:
	if rank <= 0:
		return 0.0
	var record := record_worth(tier, finishers)
	if rank <= TOP_TEN.size():
		return ceilf(record * TOP_TEN[rank - 1])

	# The slices below the top ten. Each is at least four places wide, so a small board
	# still has slices to be in rather than five that are empty.
	var n := float(maxi(finishers, 1))
	var lower := 10
	var worth := record * 0.25
	for i in range(SLICES.size()):
		var bound := maxi(int(ceil(n * SLICES[i] + 11.0)), lower + 4)
		if rank <= bound:
			return roundf(worth)
		lower = bound
		worth /= 1.5
	return 0.0


## PLACEMENT: what holding the record on a map of [param tier] with [param finishers]
## finishers is worth. Grows with the board, from a floor that rises with the tier, so a
## record on a busy hard map is worth more than one on an empty easy map.
static func record_worth(tier: int, finishers: int) -> float:
	var t := clampi(tier, 1, 10)
	var n := float(maxi(finishers, 0))
	var floor_points := 250.0 * float(t)
	# Per-tier growth with the population, and an offset once past the floor. Rising
	# faster than the tier itself, for the reason CURVE is quadratic: a tier 8 map is
	# not four times a tier 2 map.
	var growth := [0.2917, 0.56, 0.875, 1.435, 1.75, 3.5, 5.25, 7.5, 9.6, 12.0]
	var offset := [58.5, 82.15, 117.0, 164.25, 234.0, 328.0, 420.0, 560.0, 700.0, 850.0]
	var x: float = n * float(growth[t - 1])
	if t <= 2:
		return ceilf(maxf(floor_points, x + offset[t - 1]))
	return ceilf(floor_points if x < floor_points else x + offset[t - 1])


## A player's total from their records' points: best first, each one decayed by
## [param weight] per place. [param limit] keeps only the best that many; 0 keeps all.
static func weighted_total(points: Array, weight: float = 1.0, limit: int = 0) -> float:
	var sorted: Array = []
	for p in points:
		if float(p) > 0.0:
			sorted.append(float(p))
	sorted.sort()
	sorted.reverse()
	if limit > 0 and sorted.size() > limit:
		sorted = sorted.slice(0, limit)
	var total := 0.0
	var factor := 1.0
	for p in sorted:
		total += p * factor
		factor *= clampf(weight, 0.0, 1.0)
	return total


func describe() -> Dictionary:
	return {
		"formula": formula_name(formula),
		"weighting": weighting,
		"weighting_limit": weighting_limit,
		"points_per_tier": points_per_tier,
		"bonus_factor": bonus_factor,
	}
