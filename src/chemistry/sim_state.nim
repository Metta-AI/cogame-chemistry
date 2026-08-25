## Sim state, logging, the game hash, event emission and opening placement.
##
## Forked from `coworld-ctf/src/ctf/sim_state.nim`. The gameplay core lives in
## `sim.nim`; this module owns the record the core mutates and the derived
## reads (loose counts, nearest-unit queries, the hash) every other module
## needs.

import std/[json, strutils]
import sim_types, sim_config, room, events

type
  Frame* = object
    ## One recorded tick of STATE (Chemistry records state, not inputs, so
    ## playback never re-simulates). Flat integer arrays; the stride is fixed
    ## by the field order in `sim_types.nim`.
    tick*: int
    cogs*: seq[int]        ## 4 per seat: x, y, carrySpeciesId (-1), foodEaten
    molecules*: seq[int]   ## 3 per unit: x, y, speciesId
    food*: seq[int]        ## 3 per token: x, y, ttl
    reactors*: seq[int]    ## 4 per reactor: charge, stockA, stockB, cooldown

  Beat* = object
    ## One scrubber beat. `kind` is one of the five the viewer has CSS for:
    ## shift, cold, restart, famine, gameover.
    tick*: int
    kind*: string
    n*: int
    reactor*: string

  Sim* = object
    config*: GameConfig
    room*: Room
    tick*: int
    shift*: int                 ## shifts COMPLETED
    phase*: GamePhase
    cogs*: array[MaxSeats, Cog]
    reactors*: seq[Reactor]
    molGrid*: array[RoomRows, array[RoomCols, int]]   ## species id, or -1
    foodGrid*: array[RoomRows, array[RoomCols, int]]  ## age in ticks, or -1
    ventTimer*: array[Species, int]
    events*: seq[GameEvent]
    history*: seq[ShiftRecord]
    chargeSeries*: seq[seq[int]]
    frames*: seq[Frame]
    beats*: seq[Beat]
    rng*: uint64
    coldStreak*: int
    coldStarts*: int
    foodMade*: int
    foodRotted*: int
    reason*: EndReason
    ending*: EndingKind
    done*: bool
    famineLatched*: bool
    policyNames*: seq[string]
    logEnabled*: bool

proc nextRandom*(sim: var Sim): uint64 =
  ## xorshift64*, the paintbot stream. Used only for tie-free-but-arbitrary
  ## choices the rules name explicitly; none of the v1 rules do, which is what
  ## makes a seed reproduce a replay bit-exactly.
  var x = sim.rng
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  sim.rng = x
  x * 0x2545F4914F6CDD1D'u64

proc logLine*(sim: Sim, text: string) =
  if sim.logEnabled:
    echo "chemistry: ", text

proc emit*(sim: var Sim, event: GameEvent) =
  var recorded = event
  recorded.tick = sim.tick
  sim.events.add recorded

proc addBeat*(sim: var Sim, kind: string, n = 0, reactor = "") =
  sim.beats.add Beat(tick: sim.tick, kind: kind, n: n, reactor: reactor)

proc seats*(sim: Sim): int = Seats

proc moleculeAt*(sim: Sim, cell: Cell): int =
  if not cell.inBounds(): -1 else: sim.molGrid[cell.y][cell.x]

proc hasMoleculeAt*(sim: Sim, cell: Cell): bool =
  sim.moleculeAt(cell) >= 0

proc foodAt*(sim: Sim, cell: Cell): int =
  if not cell.inBounds(): -1 else: sim.foodGrid[cell.y][cell.x]

proc hasFoodAt*(sim: Sim, cell: Cell): bool =
  sim.foodAt(cell) >= 0

proc cogAt*(sim: Sim, cell: Cell): int =
  for slot in 0 ..< Seats:
    if sim.cogs[slot].cell == cell:
      return slot
  -1

proc looseCount*(sim: Sim, species: Species): int =
  let id = species.speciesId()
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      if sim.molGrid[y][x] == id:
        inc result

proc looseCells*(sim: Sim, species: Species): seq[Cell] =
  ## Row-major, so "ties by (row, col)" is the natural order.
  let id = species.speciesId()
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      if sim.molGrid[y][x] == id:
        result.add Cell(x: x, y: y)

proc foodCells*(sim: Sim): seq[Cell] =
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      if sim.foodGrid[y][x] >= 0:
        result.add Cell(x: x, y: y)

proc reactorStatus*(sim: Sim, index: int): ReactorStatus =
  let reactor = sim.reactors[index]
  if reactor.charge <= 0:
    return rsCold
  if reactor.ticksSinceReaction <= 48:
    return rsRunning
  rsStarving

proc yieldNow*(sim: Sim, index: int): int =
  ## What the NEXT reaction would produce, at the charge it would leave.
  let charge = min(sim.config.chargeMax, sim.reactors[index].charge + 1)
  1 + charge div 3

proc feedIndex*(reactor: Reactor, species: Species): int =
  if reactor.feed[0] == species: 0
  elif reactor.feed[1] == species: 1
  else: -1

proc totalShifts*(sim: Sim): int = sim.config.shifts

proc ticksTotal*(sim: Sim): int = sim.config.shifts * sim.config.ticksPerShift

proc buildFrame*(sim: Sim): Frame =
  result.tick = sim.tick
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    result.cogs.add cog.cell.x
    result.cogs.add cog.cell.y
    result.cogs.add(if cog.hasCarry: cog.carrying.speciesId() else: -1)
    result.cogs.add cog.foodEaten
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      if sim.molGrid[y][x] >= 0:
        result.molecules.add x
        result.molecules.add y
        result.molecules.add sim.molGrid[y][x]
      if sim.foodGrid[y][x] >= 0:
        result.food.add x
        result.food.add y
        result.food.add(sim.config.foodLifetime - sim.foodGrid[y][x])
  for reactor in sim.reactors:
    result.reactors.add reactor.charge
    result.reactors.add reactor.stock[0]
    result.reactors.add reactor.stock[1]
    result.reactors.add reactor.cooldown

proc frameJson*(frame: Frame): JsonNode =
  proc arr(values: seq[int]): JsonNode =
    result = newJArray()
    for value in values:
      result.add(%value)
  %*{
    "t": frame.tick,
    "c": arr(frame.cogs),
    "m": arr(frame.molecules),
    "f": arr(frame.food),
    "r": arr(frame.reactors)
  }

proc frameFromJson*(node: JsonNode): Frame =
  proc ints(value: JsonNode): seq[int] =
    if value.isNil or value.kind != JArray:
      return @[]
    for item in value:
      result.add item.getInt()
  result.tick = node{"t"}.getInt()
  result.cogs = ints(node{"c"})
  result.molecules = ints(node{"m"})
  result.food = ints(node{"f"})
  result.reactors = ints(node{"r"})

proc mixHash(value: var uint64, item: int) =
  value = value xor uint64(item and 0xFFFFFFFF)
  value = value * 0x100000001B3'u64

proc gameHash*(sim: Sim): string =
  ## FNV-1a over the recorded state. Two runs of one seed and one order
  ## script must agree here after every tick -- `tests/test_sim.nim` asserts
  ## it twice in one process and once across a fresh server.
  var value = 0xCBF29CE484222325'u64
  let frame = sim.buildFrame()
  mixHash(value, sim.tick)
  for item in frame.cogs: mixHash(value, item)
  for item in frame.molecules: mixHash(value, item)
  for item in frame.food: mixHash(value, item)
  for item in frame.reactors: mixHash(value, item)
  mixHash(value, sim.foodMade)
  mixHash(value, sim.foodRotted)
  mixHash(value, sim.coldStarts)
  toHex(value)

proc placeMolecule*(sim: var Sim, cell: Cell, species: Species) =
  sim.molGrid[cell.y][cell.x] = species.speciesId()

proc clearMolecule*(sim: var Sim, cell: Cell) =
  sim.molGrid[cell.y][cell.x] = -1

proc placeFood*(sim: var Sim, cell: Cell) =
  sim.foodGrid[cell.y][cell.x] = 0

proc clearFood*(sim: var Sim, cell: Cell) =
  sim.foodGrid[cell.y][cell.x] = -1

proc initSim*(config: GameConfig): Sim =
  ## The seeded opening state. Every seat starts on its home cell with an
  ## empty hand; every present reactor starts at `charge0` with empty stocks.
  result.config = config
  result.room = buildRoom(config)
  result.phase = Lobby
  result.reason = erComplete
  result.ending = ekShiftLimit
  result.logEnabled = true
  result.rng =
    if config.seed == 0: 0x9E3779B97F4A7C15'u64
    else: uint64(config.seed) * 0x9E3779B97F4A7C15'u64 or 1'u64
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      result.molGrid[y][x] = -1
      result.foodGrid[y][x] = -1
  for slot in 0 ..< Seats:
    result.cogs[slot] = Cog(
      slot: slot,
      alias: SeatAliases[slot],
      color: SeatColors[slot],
      cell: SeatHomes[slot],
      home: SeatHomes[slot],
      carrying: spResin,
      hasCarry: false,
      moveTimer: 0,
      lastAction: acWait)
    result.cogs[slot].order = Order(job: jobIdle, source: osScripted)
    result.cogs[slot].lastOrder = result.cogs[slot].order
  for name in config.reactorsPresent():
    result.reactors.add Reactor(
      name: name,
      cell: ReactorCells[name],
      feed: ReactorFeed[name],
      charge: config.charge0,
      cooldown: 0,
      ticksSinceReaction: 0,
      lastDeliverer: -1)
  for species in Species:
    result.ventTimer[species] = 0
  for index, name in config.players:
    if index < Seats:
      result.policyNames.add name.name
  while result.policyNames.len < Seats:
    result.policyNames.add SeatAliases[result.policyNames.len]
