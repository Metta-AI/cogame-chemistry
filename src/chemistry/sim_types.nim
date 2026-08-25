## Chemistry sim types and constants.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`: the same split (consts,
## wire types, module-global room description) with CTF's combat/flag types
## replaced by Chemistry's molecules, reactors, food and standing orders.
##
## FIELD ORDER IS SACRED, exactly as in paintbot: the replay's per-tick frame
## is a flat integer array whose stride is derived from these records, and a
## reordered field silently reinterprets every recorded frame.

import std/[strutils, unicode]

const GameVersion* = "1"
  ## GV1 (chemistry): five molecule species, three autocatalytic reactors,
  ## a 32x18 authored room, shift-scoped standing orders resolved by the
  ## courier kernel. Gates replay compatibility.

type
  ChemistryError* = object of CatchableError

const
  # ---- room geometry -------------------------------------------------------
  RoomCols* = 32
  RoomRows* = 18
  CellPx* = 48                     ## board pixels per cell
  BoardW* = RoomCols * CellPx      ## 1536
  BoardH* = RoomRows * CellPx      ## 864

  MaxSeats* = 8
  Seats* = 8                       ## Chemistry is an eight-seat game.

  # ---- playback ------------------------------------------------------------
  TargetFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 sprite whose LABEL carries the broadcast chrome JSON.
    ## `client/broadcast_core.js` routes it to onText and never draws it.

  # ---- text caps (rune counts, never bytes) --------------------------------
  MaxSayLen* = 80
  MaxNotesLen* = 320
  MaxErrorLen* = 200
  MaxPromptLen* = 4000

  # ---- default rules -------------------------------------------------------
  DefaultShifts* = 12
  DefaultTicksPerShift* = 60
  DefaultMoveCooldown* = 2
  DefaultCarryCap* = 1
  DefaultVentPeriod* = 8
  DefaultVentGroundCap* = 6
  DefaultDistractorPeriod* = 0
  DefaultDistractorGroundCap* = 12
  DefaultChargeMax* = 12
  DefaultCharge0* = 3
  DefaultChargeDecayPeriod* = 60
  DefaultReactionCooldown* = 6
  DefaultColdStartCost* = 3
  DefaultFoodLifetime* = 240
  DefaultCycles* = 3

  FamineShifts* = 3
    ## Consecutive shift boundaries with every reactor cold before the room
    ## is declared a famine.

type
  Species* = enum
    ## Wire ids are the enum ordinals: 0 resin, 1 spark, 2 brine,
    ## 3 glitter, 4 quartz. -1 on the wire means "empty hand".
    spResin = "resin"
    spSpark = "spark"
    spBrine = "brine"
    spGlitter = "glitter"
    spQuartz = "quartz"

  ReactorName* = enum
    rxAmber = "amber"
    rxBeryl = "beryl"
    rxCobalt = "cobalt"

  Job* = enum
    jobSupply = "supply"
    jobForage = "forage"
    jobHoard = "hoard"
    jobIdle = "idle"

  OrderSource* = enum
    osLlm = "llm"
    osRetry = "retry"
    osFallback = "fallback"
    osScripted = "scripted"

  Action* = enum
    acWait = "wait"
    acMoveN = "move_n"
    acMoveS = "move_s"
    acMoveE = "move_e"
    acMoveW = "move_w"
    acTake = "take"
    acDrop = "drop"

  ReactorStatus* = enum
    rsRunning = "running"
    rsStarving = "starving"
    rsCold = "cold"

  Cell* = object
    x*: int   ## column
    y*: int   ## row

  Order* = object
    ## One seat's standing order for one shift.
    job*: Job
    molecule*: Species
    hasMolecule*: bool
    reactor*: ReactorName
    hasReactor*: bool
    source*: OrderSource
    clamped*: bool
    say*: string
    notes*: string
    latencyMs*: int

  Reactor* = object
    name*: ReactorName
    cell*: Cell
    feed*: array[2, Species]
    charge*: int
    stock*: array[2, int]
    cooldown*: int
    ticksSinceReaction*: int
    lastDeliverer*: int   ## seat whose drop last entered this reactor's stock
    foodMade*: int
    reactions*: int
    shiftFoodMade*: int
    shiftReactions*: int

  Cog* = object
    slot*: int
    alias*: string
    color*: string
    cell*: Cell
    home*: Cell
    carrying*: Species
    hasCarry*: bool
    moveTimer*: int      ## ticks until a move_* is legal again
    foodEaten*: int
    delivered*: int
    misdrops*: int
    hoard*: int
    shiftEaten*: int
    order*: Order
    lastOrder*: Order
    hasOrder*: bool
    say*: string         ## last shift's broadcast line
    notes*: string       ## private, this seat only
    connected*: bool
    lastAction*: Action

  Molecule* = object
    cell*: Cell
    species*: Species

  FoodToken* = object
    cell*: Cell
    age*: int

  Vent* = object
    species*: Species
    cell*: Cell
    inert*: bool

  ShiftRecord* = object
    shift*: int
    reactions*: seq[int]
    foodMade*: seq[int]
    eaten*: array[MaxSeats, int]
    coldStarts*: int
    misdrops*: int
    charge*: seq[int]

  EndReason* = enum
    erComplete = "complete"
    erDeadline = "deadline"
    erForfeit = "forfeit"

  EndingKind* = enum
    ekShiftLimit = "shift_limit"
    ekFamine = "famine"
    ekDeadline = "deadline"
    ekForfeit = "forfeit"

  GamePhase* = enum
    Lobby = "lobby"
    Playing = "playing"
    GameOver = "gameover"

const
  SeatAliases*: array[MaxSeats, string] = [
    "Argon", "Borax", "Cinder", "Dram", "Ember", "Flint", "Gilt", "Hob"]
  SeatColors*: array[MaxSeats, string] = [
    "red", "orange", "yellow", "lime", "light blue", "blue", "pink", "white"]
  SeatHomes*: array[MaxSeats, Cell] = [
    Cell(x: 2, y: 2), Cell(x: 2, y: 4), Cell(x: 2, y: 6), Cell(x: 2, y: 8),
    Cell(x: 29, y: 2), Cell(x: 29, y: 4), Cell(x: 29, y: 6), Cell(x: 29, y: 8)]

  FeedstockSpecies*: array[3, Species] = [spResin, spSpark, spBrine]
  DistractorSpecies*: array[2, Species] = [spGlitter, spQuartz]

  VentCells*: array[Species, Cell] = [
    spResin: Cell(x: 4, y: 3),
    spSpark: Cell(x: 28, y: 3),
    spBrine: Cell(x: 16, y: 15),
    spGlitter: Cell(x: 9, y: 3),
    spQuartz: Cell(x: 23, y: 3)]

  ReactorCells*: array[ReactorName, Cell] = [
    rxAmber: Cell(x: 16, y: 4),
    rxBeryl: Cell(x: 23, y: 11),
    rxCobalt: Cell(x: 9, y: 11)]

  ReactorFeed*: array[ReactorName, array[2, Species]] = [
    rxAmber: [spResin, spSpark],
    rxBeryl: [spSpark, spBrine],
    rxCobalt: [spResin, spBrine]]

  PillarCells*: array[8, Cell] = [
    Cell(x: 13, y: 8), Cell(x: 14, y: 8), Cell(x: 13, y: 9), Cell(x: 14, y: 9),
    Cell(x: 18, y: 8), Cell(x: 19, y: 8), Cell(x: 18, y: 9), Cell(x: 19, y: 9)]

proc `==`*(a, b: Cell): bool = a.x == b.x and a.y == b.y

proc manhattan*(a, b: Cell): int =
  abs(a.x - b.x) + abs(a.y - b.y)

proc isInert*(species: Species): bool =
  species == spGlitter or species == spQuartz

proc speciesId*(species: Species): int = ord(species)

proc speciesFromId*(id: int): Species =
  if id < 0 or id > ord(Species.high):
    raise newException(ChemistryError, "bad species id: " & $id)
  Species(id)

proc parseSpecies*(text: string): tuple[ok: bool, species: Species] =
  for species in Species:
    if $species == text.strip().toLowerAscii():
      return (true, species)
  (false, spResin)

proc parseReactorName*(text: string): tuple[ok: bool, reactor: ReactorName] =
  for name in ReactorName:
    if $name == text.strip().toLowerAscii():
      return (true, name)
  (false, rxAmber)

proc parseJob*(text: string): tuple[ok: bool, job: Job] =
  for job in Job:
    if $job == text.strip().toLowerAscii():
      return (true, job)
  (false, jobIdle)

proc cleanText*(text: string, limit: int): string =
  ## Rune-safe truncation. A byte cut put invalid UTF-8 into a replay and only
  ## a strict parser found it (bullwhip, 2026-08-22), so EVERY string that
  ## reaches the replay goes through here.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

proc sayText*(text: string): string =
  ## `say` additionally folds newlines to spaces before the rune cut.
  cleanText(text.replace("\n", " ").replace("\r", " "), MaxSayLen)

proc notesText*(text: string): string =
  cleanText(text, MaxNotesLen)

proc errorText*(text: string): string =
  cleanText(text.replace("\n", " "), MaxErrorLen)
