## The Chemistry event vocabulary.
##
## Forked from `coworld-ctf/src/ctf/events.nim`: one JSON row per event, the
## same `jsonRow` / `eventsJson` shape, and the same rule that live emission
## and replay playback must produce byte-identical rows.

import std/json
import sim_types

type
  EventKind* = enum
    evTake = "take"
    evDrop = "drop"
    evMisdrop = "misdrop"
    evReact = "react"
    evRestart = "restart"
    evCold = "cold"
    evEat = "eat"
    evRot = "rot"
    evSpoil = "spoil"
    evOrder = "order"
    evShift = "shift"
    evFamine = "famine"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    tick*: int
    seat*: int            ## -1 when the event has no seat
    species*: Species
    hasSpecies*: bool
    reactor*: ReactorName
    hasReactor*: bool
    x*, y*: int
    charge*: int
    foodYield*: int
    by*: int              ## react/restart: the triggering seat, -1 if none
    lost*: int            ## spoil: tokens with nowhere to land
    shift*: int
    job*: Job
    source*: OrderSource
    clamped*: bool
    say*: string
    notes*: string
    latencyMs*: int
    charges*: seq[int]
    foodMade*: seq[int]
    eaten*: seq[int]
    misdrops*: int
    coldStarts*: int
    reason*: EndReason
    ending*: EndingKind
    scores*: seq[int]

proc intArray(values: openArray[int]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc jsonRow*(event: GameEvent): JsonNode =
  ## One replay `events[]` row. Every string here has already been rune-cut
  ## by `cleanText` at the point it entered the sim.
  result = %*{"t": event.tick, "k": $event.kind}
  case event.kind
  of evTake:
    result["seat"] = %event.seat
    result["sp"] = %($event.species)
    result["x"] = %event.x
    result["y"] = %event.y
  of evDrop:
    result["seat"] = %event.seat
    result["sp"] = %($event.species)
    result["x"] = %event.x
    result["y"] = %event.y
    result["rx"] = %(if event.hasReactor: $event.reactor else: "")
  of evMisdrop:
    result["seat"] = %event.seat
    result["sp"] = %($event.species)
    result["rx"] = %($event.reactor)
  of evReact:
    result["rx"] = %($event.reactor)
    result["charge"] = %event.charge
    result["yield"] = %event.foodYield
    result["by"] = %event.by
  of evRestart:
    result["rx"] = %($event.reactor)
    result["by"] = %event.by
  of evCold:
    result["rx"] = %($event.reactor)
  of evEat:
    result["seat"] = %event.seat
    result["x"] = %event.x
    result["y"] = %event.y
  of evRot:
    result["x"] = %event.x
    result["y"] = %event.y
  of evSpoil:
    result["rx"] = %($event.reactor)
    result["lost"] = %event.lost
  of evOrder:
    result["seat"] = %event.seat
    result["shift"] = %event.shift
    result["job"] = %($event.job)
    result["sp"] = %(if event.hasSpecies: $event.species else: "")
    result["rx"] = %(if event.hasReactor: $event.reactor else: "")
    result["source"] = %($event.source)
    result["clamped"] = %event.clamped
    result["say"] = %event.say
    result["notes"] = %event.notes
    result["latencyMs"] = %event.latencyMs
  of evShift:
    result["shift"] = %event.shift
    result["charge"] = intArray(event.charges)
    result["foodMade"] = intArray(event.foodMade)
    result["eaten"] = intArray(event.eaten)
    result["misdrops"] = %event.misdrops
    result["coldStarts"] = %event.coldStarts
  of evFamine:
    discard
  of evEnd:
    result["reason"] = %($event.reason)
    result["ending"] = %($event.ending)
    result["scores"] = intArray(event.scores)

proc eventsJson*(events: openArray[GameEvent]): JsonNode =
  result = newJArray()
  for event in events:
    result.add event.jsonRow()

proc eventsJsonl*(events: openArray[GameEvent]): string =
  ## One row per line, for `tools/` log consumers and the CI event dumps.
  for event in events:
    result.add($event.jsonRow())
    result.add("\n")
