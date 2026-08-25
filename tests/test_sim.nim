## Sim units: the nine numbered steps, each precondition, and determinism.

import std/[strutils, unicode, unittest]
import chemistry/sim

proc idleSim(cycles = 3, distractorPeriod = 0): Sim =
  var config = defaultGameConfig()
  config.seed = 1
  config.cycles = cycles
  config.distractorPeriod = distractorPeriod
  config.distractorGroundCap = 24
  result = initSim(config)
  result.logEnabled = false
  for slot in 0 ..< Seats:
    result.cogs[slot].order = Order(job: jobIdle, source: osScripted)

proc countEvents(sim: Sim, kind: EventKind): int =
  for event in sim.events:
    if event.kind == kind:
      inc result

proc lastEvent(sim: Sim, kind: EventKind): GameEvent =
  for index in countdown(sim.events.high, 0):
    if sim.events[index].kind == kind:
      return sim.events[index]
  raise newException(ValueError, "no " & $kind & " event")

suite "room geometry":
  test "the authored room is walls, pads, vents and homes":
    let sim = idleSim()
    check sim.room.isWall(Cell(x: 0, y: 0))
    check sim.room.isWall(Cell(x: 31, y: 17))
    check sim.room.isWall(Cell(x: 13, y: 8))
    check sim.room.isWall(Cell(x: 19, y: 9))
    check sim.room.isFloor(Cell(x: 16, y: 4))
    for home in SeatHomes:
      check sim.room.isFloor(home)
    for species in FeedstockSpecies:
      check sim.room.isFloor(VentCells[species])
    ## Every spill ring is the 12 cells orthogonally or diagonally
    ## surrounding the 3x3 pad.
    for ring in sim.room.spill:
      check ring.len == 12
    for pad in sim.room.pad:
      check pad.len == 9

  test "BFS is deterministic: the same state yields the same path twice":
    let sim = idleSim()
    let a = sim.room.distanceField([Cell(x: 16, y: 4)])
    let b = sim.room.distanceField([Cell(x: 16, y: 4)])
    for y in 0 ..< RoomRows:
      for x in 0 ..< RoomCols:
        check a.dist[y][x] == b.dist[y][x]
    check a.distanceTo(Cell(x: 4, y: 3)) > 0
    ## Walls are never reachable, floor always is.
    check a.distanceTo(Cell(x: 0, y: 0)) == -1

suite "reactions":
  test "charge 0 blocks a reaction; cooldown blocks it; a zero stock blocks it":
    var sim = idleSim()
    sim.reactors[0].charge = 0
    sim.reactors[0].stock = [1, 1]
    sim.stepTick()
    check sim.countEvents(evReact) == 0

    sim = idleSim()
    sim.reactors[0].charge = 3
    sim.reactors[0].cooldown = 5
    sim.reactors[0].stock = [1, 1]
    sim.stepTick()
    check sim.countEvents(evReact) == 0

    sim = idleSim()
    sim.reactors[0].charge = 3
    sim.reactors[0].stock = [1, 0]
    sim.stepTick()
    check sim.countEvents(evReact) == 0

    sim = idleSim()
    sim.reactors[0].charge = 3
    sim.reactors[0].stock = [1, 1]
    sim.stepTick()
    check sim.countEvents(evReact) == 1

  test "foodYield is 1 + charge div 3 on the POST-increment charge":
    for charge in 1 .. 12:
      var sim = idleSim()
      sim.reactors[0].charge = charge
      sim.reactors[0].stock = [1, 1]
      sim.stepTick()
      let event = sim.lastEvent(evReact)
      let after = min(sim.config.chargeMax, charge + 1)
      check event.charge == after
      check event.foodYield == 1 + after div 3

  test "a cold start consumes exactly coldStartCost of EACH feedstock and makes no food":
    var sim = idleSim()
    sim.reactors[0].charge = 0
    sim.reactors[0].stock = [4, 3]
    sim.stepTick()
    check sim.countEvents(evRestart) == 1
    check sim.countEvents(evReact) == 0
    check sim.reactors[0].stock == [1, 0]
    check sim.reactors[0].charge == 1
    check sim.foodMade == 0
    check sim.coldStarts == 1

  test "a cold reactor one unit short of the cold-start cost does nothing":
    var sim = idleSim()
    sim.reactors[0].charge = 0
    sim.reactors[0].stock = [3, 2]
    sim.stepTick()
    check sim.countEvents(evRestart) == 0
    check sim.reactors[0].stock == [3, 2]

  test "reactionCooldown spaces reactions":
    var sim = idleSim()
    sim.reactors[0].charge = 3
    sim.reactors[0].stock = [10, 10]
    for tick in 1 .. 13:
      sim.stepTick()
    ## Ticks 1, 7 and 13 react at reactionCooldown = 6.
    check sim.reactors[0].reactions == 3

suite "decay and rot":
  test "charge decays on tick mod chargeDecayPeriod and emits cold at the 0 crossing":
    var sim = idleSim()
    for index in 0 ..< sim.reactors.len:
      sim.reactors[index].charge = 1
    for tick in 1 ..< sim.config.chargeDecayPeriod:
      sim.stepTick()
      check sim.reactors[0].charge == 1
    sim.stepTick()
    check sim.tick == sim.config.chargeDecayPeriod
    for reactor in sim.reactors:
      check reactor.charge == 0
    check sim.countEvents(evCold) == sim.reactors.len
    var coldBeats = 0
    for beat in sim.beats:
      if beat.kind == "cold": inc coldBeats
    check coldBeats == sim.reactors.len

  test "a food token rots at exactly foodLifetime ticks":
    var sim = idleSim()
    let cell = Cell(x: 6, y: 6)
    sim.placeFood(cell)
    for tick in 1 ..< sim.config.foodLifetime:
      sim.stepTick()
      check sim.hasFoodAt(cell)
    sim.stepTick()
    check not sim.hasFoodAt(cell)
    check sim.countEvents(evRot) == 1
    check sim.foodRotted == 1

suite "vents":
  test "a vent emits N, E, S, W in order and stops at the ground cap":
    var sim = idleSim()
    let vent = VentCells[spResin]
    ## Tick 8 is the first emission at ventPeriod 8.
    for tick in 1 .. 8:
      sim.stepTick()
    check sim.hasMoleculeAt(vent.neighbour(0))
    for tick in 9 .. 16:
      sim.stepTick()
    check sim.hasMoleculeAt(vent.neighbour(1))
    ## Fill the floor to the cap and the vent falls silent.
    var sim2 = idleSim()
    var placed = 0
    for y in 5 .. 12:
      for x in 5 .. 12:
        if placed >= sim2.config.ventGroundCap: break
        sim2.placeMolecule(Cell(x: x, y: y), spResin)
        inc placed
    check sim2.looseCount(spResin) == sim2.config.ventGroundCap
    for tick in 1 .. 8:
      sim2.stepTick()
    check sim2.looseCount(spResin) == sim2.config.ventGroundCap

  test "distractor vents exist only when distractorPeriod is positive":
    let plain = idleSim(3, 0)
    check not plain.config.hasSpecies(spGlitter)
    let littered = idleSim(3, 2)
    check littered.config.hasSpecies(spQuartz)

suite "cogs":
  test "carryCap 1: a full hand cannot take":
    var sim = idleSim()
    sim.cogs[0].cell = Cell(x: 6, y: 6)
    sim.cogs[0].carrying = spSpark
    sim.cogs[0].hasCarry = true
    sim.placeMolecule(Cell(x: 6, y: 6), spResin)
    sim.cogs[0].order = Order(job: jobSupply, molecule: spResin,
      hasMolecule: true, reactor: rxAmber, hasReactor: true)
    sim.stepTick()
    check sim.cogs[0].carrying == spSpark
    check sim.hasMoleculeAt(Cell(x: 6, y: 6)) or sim.cogs[0].cell != Cell(x: 6, y: 6)

  test "move cooldown: a cog moves once every moveCooldown ticks":
    var sim = idleSim()
    sim.cogs[0].cell = Cell(x: 5, y: 5)
    sim.cogs[0].order = Order(job: jobSupply, molecule: spResin,
      hasMolecule: true, reactor: rxAmber, hasReactor: true)
    sim.cogs[0].hasCarry = true
    sim.cogs[0].carrying = spResin
    var moves = 0
    var last = sim.cogs[0].cell
    for tick in 1 .. 20:
      sim.stepTick()
      if sim.cogs[0].cell != last:
        inc moves
        last = sim.cogs[0].cell
    check moves <= 20 div sim.config.moveCooldown
    check moves >= 20 div sim.config.moveCooldown - 1

  test "two cogs cannot share a cell and the lower slot wins":
    var sim = idleSim()
    ## Both want (10, 6): slot 0 from the west, slot 1 from the east.
    sim.cogs[0].cell = Cell(x: 9, y: 6)
    sim.cogs[1].cell = Cell(x: 11, y: 6)
    for slot in 2 ..< Seats:
      sim.cogs[slot].cell = Cell(x: 2 + slot, y: 15)
    sim.placeMolecule(Cell(x: 10, y: 6), spResin)
    for slot in 0 .. 1:
      sim.cogs[slot].order = Order(job: jobSupply, molecule: spResin,
        hasMolecule: true, reactor: rxAmber, hasReactor: true)
    sim.stepTick()
    check sim.cogs[0].cell == Cell(x: 10, y: 6)
    check sim.cogs[1].cell != sim.cogs[0].cell
    for slot in 0 ..< Seats:
      for other in 0 ..< Seats:
        if slot != other:
          check sim.cogs[slot].cell != sim.cogs[other].cell

  test "a misdrop destroys the molecule and increments the delivering seat":
    var sim = idleSim()
    ## Beryl takes spark + brine; resin is absorbed.
    let pad = ReactorCells[rxBeryl]
    sim.cogs[3].cell = pad
    sim.cogs[3].carrying = spResin
    sim.cogs[3].hasCarry = true
    sim.cogs[3].lastAction = acDrop
    sim.cogs[3].order = Order(job: jobSupply, molecule: spResin,
      hasMolecule: true, reactor: rxBeryl, hasReactor: true)
    sim.stepTick()
    check sim.cogs[3].misdrops == 1
    check sim.cogs[3].delivered == 0
    check not sim.cogs[3].hasCarry
    check not sim.hasMoleculeAt(pad)
    let index = sim.room.reactorIndex(rxBeryl)
    check sim.reactors[index].stock == [0, 0]

suite "food placement":
  test "tokens land nearest the deliverer, ties by (row, col)":
    var sim = idleSim()
    let index = 0
    let ring = sim.room.spill[index]
    ## Park the deliverer on one ring cell and fire a big yield.
    sim.reactors[index].lastDeliverer = 5
    sim.cogs[5].cell = ring[0]
    sim.placeFoodTokens(index, 3, 5)
    var placed: seq[Cell]
    for cell in ring:
      if sim.hasFoodAt(cell):
        placed.add cell
    check placed.len == 3
    ## The nearest ring cell to the deliverer must be among them.
    var nearest = ring[0]
    var best = high(int)
    for cell in ring:
      let distance = manhattan(cell, sim.cogs[5].cell)
      if distance < best or (distance == best and
          (cell.y < nearest.y or (cell.y == nearest.y and cell.x < nearest.x))):
        best = distance
        nearest = cell
    check sim.hasFoodAt(nearest)

  test "a full ring spoils the surplus":
    var sim = idleSim()
    let index = 1
    for cell in sim.room.spill[index]:
      sim.placeFood(cell)
    let before = sim.foodMade
    sim.placeFoodTokens(index, 4, -1)
    check sim.foodMade == before
    check sim.countEvents(evSpoil) == 1
    check sim.lastEvent(evSpoil).lost == 4

suite "determinism":
  proc scripted(seed: int): Sim =
    var config = defaultGameConfig()
    config.seed = seed
    config.cycles = 3
    config.distractorPeriod = 2
    config.distractorGroundCap = 24
    result = initSim(config)
    result.logEnabled = false
    while not result.done:
      for slot in 0 ..< Seats:
        result.applyOrder(slot, result.courierOrder(slot))
      result.runShift()

  test "one seed and one order script produce an identical gameHash, twice":
    let a = scripted(4242)
    let b = scripted(4242)
    check a.tick == 720
    check a.gameHash() == b.gameHash()
    check a.frames.len == 720
    check a.chargeSeries.len == 720

  test "a fresh server reproduces the same hash":
    ## `initSim` is the only entry into a game, so a "fresh server" is a fresh
    ## config + initSim; anything seed-derived that leaked across episodes
    ## would show here.
    var hashes: seq[string]
    for attempt in 0 .. 2:
      hashes.add scripted(99).gameHash()
    check hashes[0] == hashes[1]
    check hashes[1] == hashes[2]

  test "different order scripts diverge":
    var config = defaultGameConfig()
    config.seed = 4242
    var free = initSim(config)
    free.logEnabled = false
    while not free.done:
      for slot in 0 ..< Seats:
        free.applyOrder(slot, free.freeloaderOrder(slot))
      free.runShift()
    check free.gameHash() != scripted(4242).gameHash()

suite "rune-safe truncation":
  test "every recorded string is cut on a rune boundary":
    let long = "\u00e9".repeat(400)
    let say = sayText(long)
    let notes = notesText(long)
    check validateUtf8(say) == -1
    check validateUtf8(notes) == -1
    check say.runeLen <= MaxSayLen
    check notes.runeLen <= MaxNotesLen
    check errorText(long).runeLen <= MaxErrorLen
    ## Newlines in `say` become spaces.
    check "\n" notin sayText("a\nb")
