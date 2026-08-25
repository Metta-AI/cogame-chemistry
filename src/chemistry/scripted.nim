## The two scripted baselines, both fieldable policies and both league
## fillers. `courier` is also the fallback every failed LLM decision lands on,
## so it must be legal for every variant by construction --
## `tests/test_baseline.nim` asserts exactly that.
##
## Both decide purely from the observation and their own slot number: no
## shared state, so eight couriers coordinate implicitly by computing the same
## lane table.

import std/[algorithm, strutils]
import sim_types, sim_config, sim_state

type
  ScriptKind* = enum
    skNone = "none"
    skCourier = "courier"
    skFreeloader = "freeloader"

  Lane* = object
    reactor*: ReactorName
    reactorIndex*: int
    species*: Species
    need*: int
    charge*: int
    order*: int      ## fixed lane order: amber-resin, amber-spark, beryl-spark,
                     ## beryl-brine, cobalt-resin, cobalt-brine

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values. "1"/"true"/"yes"/"courier" play the working
  ## baseline; "freeloader"/"shirker" play the shirker; anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "courier": skCourier
  of "freeloader", "shirker", "forager": skFreeloader
  else: skNone

proc titleCase(text: string): string =
  if text.len == 0: text
  else: text[0..0].toUpperAscii() & text[1 .. ^1]

proc laneTable*(sim: Sim): seq[Lane] =
  ## Every (reactor, feedstock) supply lane present in this variant, with the
  ## shortfall each one is running. `target` is the cold-start cost while the
  ## reactor is dead (restarting it needs 3 of EACH), else a working 2.
  var index = 0
  for reactorIndex in 0 ..< sim.reactors.len:
    let reactor = sim.reactors[reactorIndex]
    for feed in 0 .. 1:
      let target =
        if reactor.charge == 0: sim.config.coldStartCost
        else: 2
      result.add Lane(
        reactor: reactor.name,
        reactorIndex: reactorIndex,
        species: reactor.feed[feed],
        need: target - reactor.stock[feed],
        charge: reactor.charge,
        order: index)
      inc index

proc sortLanes*(lanes: var seq[Lane]) =
  ## need descending, then reactor charge ascending (feed the dying cycle
  ## first), then the fixed lane order.
  lanes.sort(proc (a, b: Lane): int =
    if a.need != b.need: cmp(b.need, a.need)
    elif a.charge != b.charge: cmp(a.charge, b.charge)
    else: cmp(a.order, b.order))

proc highestChargeReactor*(sim: Sim): ReactorName =
  var best = 0
  var bestCharge = -1
  for index in 0 ..< sim.reactors.len:
    if sim.reactors[index].charge > bestCharge:
      bestCharge = sim.reactors[index].charge
      best = index
  sim.reactors[best].name

proc courierOrder*(sim: Sim, slot: int): Order =
  ## The working baseline. With 8 seats and 6 lanes, slots 0-5 take one lane
  ## each -- in the FIXED lane order, so a courier keeps its lane across shift
  ## boundaries instead of being re-tasked mid-trip -- and slots 6-7 double up
  ## on the two neediest. That is exactly the labour the throughput arithmetic
  ## says the room needs, and the stability is what makes it land: a lane
  ## whose owner changes every shift is a lane nobody ever finishes a trip to.
  let fixed = sim.laneTable()
  var priority = fixed
  sortLanes(priority)
  result.source = osScripted
  if priority.len == 0 or priority[0].need <= 0:
    result.job = jobForage
    result.reactor = sim.highestChargeReactor()
    result.hasReactor = true
    result.say = sayText("all vats stocked - eating")
    return
  let lane =
    if slot < fixed.len: fixed[slot]
    else: priority[(slot - fixed.len) mod priority.len]
  result.job = jobSupply
  result.molecule = lane.species
  result.hasMolecule = true
  result.reactor = lane.reactor
  result.hasReactor = true
  result.say = sayText($lane.species & " to " & titleCase($lane.reactor))

proc freeloaderOrder*(sim: Sim, slot: int): Order =
  ## The shirker, and the idea's "background shirker bot". One exception, so a
  ## room of eight freeloaders is never a guaranteed zero and never deadlocks
  ## the episode: with EVERY reactor cold it takes the single largest-need lane.
  result.source = osScripted
  var allCold = true
  for reactor in sim.reactors:
    if reactor.charge > 0:
      allCold = false
  if allCold and sim.reactors.len > 0:
    var lanes = sim.laneTable()
    sortLanes(lanes)
    result.job = jobSupply
    result.molecule = lanes[0].species
    result.hasMolecule = true
    result.reactor = lanes[0].reactor
    result.hasReactor = true
    result.say = sayText("vats are dead - restarting " &
      titleCase($lanes[0].reactor))
    return
  result.job = jobForage
  result.reactor = sim.highestChargeReactor()
  result.hasReactor = true
  result.say = sayText("waiting by the vats")

proc scriptedOrder*(sim: Sim, slot: int, kind: ScriptKind): Order =
  case kind
  of skFreeloader: sim.freeloaderOrder(slot)
  else: sim.courierOrder(slot)
