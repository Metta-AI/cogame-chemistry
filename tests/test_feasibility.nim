## The feasibility oracle, as a CI precondition.
##
## Gates (a)-(d) of the design note's `## Throughput arithmetic`, over seeds
## 1..12 on all four variants. Any constant change that breaks the economy
## fails HERE rather than in a dead replay -- this test is the enforcement,
## not the table in the note.
##
## The design note's stated repair order, if a gate ever fails:
##   (a) ventPeriod 8 -> 6, then moveCooldown 2 -> 1, then
##       chargeDecayPeriod 60 -> 72
##   (b) foodLifetime 240 -> 180
##   (c) charge0 3 -> 2
##   (d) distractorPeriod 2 -> 1
## As shipped, NO repair was needed: every gate passes on the note's own
## constants.

import std/[unittest]
import chemistry/sim

type Variant = tuple[name: string, cycles, distractorPeriod, distractorCap: int]

const Variants: array[4, Variant] = [
  ("two-cycles", 2, 0, 0),
  ("two-cycles-distractors", 2, 6, 12),
  ("three-cycles", 3, 0, 0),
  ("three-cycles-plentiful-distractors", 3, 2, 24)]

const Seeds = 1 .. 12

proc configFor(variant: Variant, seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.cycles = variant.cycles
  result.distractorPeriod = variant.distractorPeriod
  result.distractorGroundCap = variant.distractorCap

## The test-only `nearest` kernel of gate (d): take the nearest molecule of ANY
## species and carry it to the nearest reactor. It lives HERE and is not a
## shipped policy.
proc nearestOrder(sim: Sim, slot: int): Order =
  let me = sim.cogs[slot].cell
  var bestSpecies = spResin
  var bestDistance = high(int)
  var found = false
  for species in sim.config.speciesPresent():
    for cell in sim.looseCells(species):
      let distance = manhattan(cell, me)
      if distance < bestDistance:
        bestDistance = distance
        bestSpecies = species
        found = true
  if not found:
    return Order(job: jobForage, source: osScripted,
      reactor: sim.highestChargeReactor(), hasReactor: true)
  var bestReactor = sim.reactors[0].name
  var reactorDistance = high(int)
  for reactor in sim.reactors:
    let distance = manhattan(reactor.cell, me)
    if distance < reactorDistance:
      reactorDistance = distance
      bestReactor = reactor.name
  Order(job: jobSupply, molecule: bestSpecies, hasMolecule: true,
    reactor: bestReactor, hasReactor: true, source: osScripted)

proc play(variant: Variant, seed: int, kinds: array[Seats, ScriptKind],
          nearestSeats: set[0 .. 7] = {}): Sim =
  result = initSim(configFor(variant, seed))
  result.logEnabled = false
  while not result.done:
    for slot in 0 ..< Seats:
      let order =
        if slot in nearestSeats: result.nearestOrder(slot)
        else: result.scriptedOrder(slot, kinds[slot])
      result.applyOrder(slot, order)
    result.runShift()

proc allOf(kind: ScriptKind): array[Seats, ScriptKind] =
  for slot in 0 ..< Seats:
    result[slot] = kind

suite "feasibility oracle":
  test "(a) the baselines sustain the room":
    for variant in Variants:
      var good = 0
      for seed in Seeds:
        let sim = play(variant, seed, allOf(skCourier))
        var alive = true
        for reactor in sim.reactors:
          if reactor.charge < 1: alive = false
        var lowest = high(int)
        for slot in 0 ..< Seats:
          lowest = min(lowest, sim.cogs[slot].foodEaten)
        if alive and sim.foodMade >= 40 and lowest >= 3:
          inc good
        check sim.ending == ekShiftLimit
        check sim.reason == erComplete
      checkpoint variant.name & ": " & $good & "/12 seeds sustained"
      check good >= 10

  test "(b) the temptation is real":
    for variant in Variants:
      var kinds = allOf(skCourier)
      kinds[6] = skFreeloader
      kinds[7] = skFreeloader
      var courierTotal = 0
      var freeloaderTotal = 0
      for seed in Seeds:
        let sim = play(variant, seed, kinds)
        for slot in 0 .. 5:
          courierTotal += sim.cogs[slot].foodEaten
        for slot in 6 .. 7:
          freeloaderTotal += sim.cogs[slot].foodEaten
      let courierMean = courierTotal / (6 * 12)
      let freeloaderMean = freeloaderTotal / (2 * 12)
      checkpoint variant.name & ": courier " & $courierMean &
        " vs freeloader " & $freeloaderMean
      check freeloaderMean > courierMean

  test "(c) shirking is collectively self-defeating":
    for variant in Variants:
      var courierFood = 0
      var freeloaderFood = 0
      var famines = 0
      for seed in Seeds:
        courierFood += play(variant, seed, allOf(skCourier)).foodMade
        let lazy = play(variant, seed, allOf(skFreeloader))
        freeloaderFood += lazy.foodMade
        if lazy.ending == ekFamine:
          inc famines
      checkpoint variant.name & ": lazy " & $freeloaderFood & " vs working " &
        $courierFood & ", famines " & $famines
      check (freeloaderFood * 100 < courierFood * 15) or famines == Seeds.len

  test "(d) distractors bite":
    ## On the plentiful-distractor room the `nearest` kernel must score below
    ## 0.6 x the `courier` mean.
    let variant = Variants[3]
    var courierTotal = 0
    var nearestTotal = 0
    for seed in Seeds:
      let working = play(variant, seed, allOf(skCourier))
      for slot in 0 ..< Seats:
        courierTotal += working.cogs[slot].foodEaten
      let grabby = play(variant, seed, allOf(skCourier),
        nearestSeats = {0, 1, 2, 3, 4, 5, 6, 7})
      for slot in 0 ..< Seats:
        nearestTotal += grabby.cogs[slot].foodEaten
    let courierMean = courierTotal / (Seats * 12)
    let nearestMean = nearestTotal / (Seats * 12)
    checkpoint "courier mean " & $courierMean & " vs nearest mean " &
      $nearestMean
    check nearestMean < 0.6 * courierMean
