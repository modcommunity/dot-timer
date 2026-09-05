class_name DotTimerTrack
extends RefCounted

## Which route through a map a run is on: the main one, or one of its bonuses.
##
## [b]A namespace, not an object.[/b] Nothing is ever instantiated — a track is an
## [code]int[/code] everywhere it appears, because it is a column in a records table,
## a field on the wire, and an index into an array of zones. Wrapping it in a class
## would mean allocating one per record.
##
## The numbering is the community timers', and it is worth keeping compatible: 0 is
## the main track
## and 1..8 are bonuses. Maps in this genre are shared between servers and referred to
## by the same numbers by the people who run them, so "bonus 2" has to mean bonus 2.

## The main route. Every map has one.
const MAIN := 0

## The first bonus. Bonuses are [constant BONUS_FIRST] .. [constant BONUS_LAST].
const BONUS_FIRST := 1
const BONUS_LAST := 8

## One past the last valid track, so a loop reads [code]for t in range(COUNT)[/code].
const COUNT := BONUS_LAST + 1

## Bits a track occupies on the wire. Four is exactly enough for 0..8.
const BITS := 4


static func is_valid(track: int) -> bool:
	return track >= MAIN and track < COUNT


static func is_bonus(track: int) -> bool:
	return track >= BONUS_FIRST and track <= BONUS_LAST


## The bonus number a track is, or 0 for the main track.
static func bonus_number(track: int) -> int:
	return track if is_bonus(track) else 0


## A track id from a bonus number. [code]of_bonus(2)[/code] is bonus 2.
static func of_bonus(number: int) -> int:
	return clampi(number, BONUS_FIRST, BONUS_LAST)


static func name_of(track: int) -> String:
	if track == MAIN:
		return "Main"
	if is_bonus(track):
		return "Bonus %d" % track
	return "Track %d" % track


## A short label for a HUD column or a chat tag.
static func short_name_of(track: int) -> String:
	if track == MAIN:
		return "main"
	if is_bonus(track):
		return "b%d" % track
	return "t%d" % track


## Parses "main", "bonus", "bonus 3", "b3", "2". [code]-1[/code] when it is none of
## those.
##
## Returning -1 rather than falling back to the main track is deliberate: a console
## command that quietly reads "bonus 9" as "main" sets a record on the wrong track,
## and the player who typed it has no way to tell.
static func parse(text: String) -> int:
	var cleaned := text.strip_edges().to_lower()

	if cleaned == "" or cleaned == "main" or cleaned == "0":
		return MAIN

	if cleaned == "bonus" or cleaned == "b":
		return BONUS_FIRST

	if cleaned.begins_with("bonus"):
		cleaned = cleaned.substr(5).strip_edges()
	elif cleaned.begins_with("b") and cleaned.length() > 1:
		cleaned = cleaned.substr(1).strip_edges()

	if not cleaned.is_valid_int():
		return -1

	var number := cleaned.to_int()

	return number if is_valid(number) else -1
