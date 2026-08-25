## The Chemistry gameplay core: the nine numbered tick-resolution steps, the
## shift loop, the end conditions and the results object.
##
## Forked from `coworld-ctf/src/ctf/sim.nim` -- same shape (a `SimServer`-style
## record stepped one tick at a time, imports and RE-EXPORTS the split modules
## so `import chemistry/sim` still sees everything), with the CTF gameplay core
## replaced by the reaction graph.
##
## Within a step, seats resolve in ASCENDING SLOT ORDER and reactors in the
## fixed order amber, beryl, cobalt. All reads inside a step use the state as
## it stood at the start of that step unless the step says otherwise.

import std/[algorithm, json]
import sim_types, sim_config, room, events, sim_state, kernel, scripted

export sim_types, sim_config, room, events, sim_state, kernel, scripted

proc ventPeriodFor(config: GameConfig, species: Species): int =
  if species.isInert(): config.distractorPeriod
  else: config.ventPeriod

proc ventCapFor(config: GameConfig, species: Species): int =
  if species.isInert(): config.distractorGroundCap
  else: config.ventGroundCap

# --------------------------------------------------------------------------
# Step 1 -- vents emit
# --------------------------------------------------------------------------

proc stepVents(sim: var Sim) =
  for species in Species:
    if not sim.config.hasSpecies(species):
      continue
    let period = sim.config.ventPeriodFor(species)
    if period <= 0 or sim.tick mod period != 0:
      continue
    if sim.looseCount(species) >= sim.config.ventCapFor(species):
      continue
    let vent = VentCells[species]
    for direction in 0 .. 3:
      let cell = vent.neighbour(direction)
      if sim.room.isFloor(cell) and not sim.hasMoleculeAt(cell):
        sim.placeMolecule(cell, species)
        break

# --------------------------------------------------------------------------
# Step 2 -- kernel intent
# --------------------------------------------------------------------------

proc stepIntent(sim: var Sim) =
  var actions: array[MaxSeats, Action]
  for slot in 0 ..< Seats:
    var action = sim.kernelAction(slot)
    if sim.cogs[slot].moveTimer > 0 and
        action in {acMoveN, acMoveS, acMoveE, acMoveW}:
      action = acWait
    actions[slot] = action
  for slot in 0 ..< Seats:
    sim.cogs[slot].lastAction = actions[slot]

# --------------------------------------------------------------------------
# Step 3 -- take / drop
# --------------------------------------------------------------------------

proc stepTakeDrop(sim: var Sim) =
  for slot in 0 ..< Seats:
    let cell = sim.cogs[slot].cell
    case sim.cogs[slot].lastAction
    of acTake:
      if sim.cogs[slot].hasCarry or not sim.hasMoleculeAt(cell):
        sim.cogs[slot].lastAction = acWait
        continue
      let species = speciesFromId(sim.moleculeAt(cell))
      sim.clearMolecule(cell)
      sim.cogs[slot].carrying = species
      sim.cogs[slot].hasCarry = true
      sim.emit GameEvent(kind: evTake, seat: slot, species: species,
        hasSpecies: true, x: cell.x, y: cell.y)
    of acDrop:
      if not sim.cogs[slot].hasCarry:
        sim.cogs[slot].lastAction = acWait
        continue
      let species = sim.cogs[slot].carrying
      let pad = sim.room.padAt(cell)
      if pad >= 0:
        let feed = sim.reactors[pad].feedIndex(species)
        if feed >= 0:
          sim.reactors[pad].stock[feed].inc
          sim.reactors[pad].lastDeliverer = slot
          sim.cogs[slot].delivered.inc
          sim.cogs[slot].hasCarry = false
          sim.emit GameEvent(kind: evDrop, seat: slot, species: species,
            hasSpecies: true, x: cell.x, y: cell.y,
            reactor: sim.reactors[pad].name, hasReactor: true)
        else:
          ## Absorbed and destroyed: the reaction graph test, priced in
          ## matter rather than in a repair job.
          sim.cogs[slot].misdrops.inc
          sim.cogs[slot].hasCarry = false
          sim.emit GameEvent(kind: evMisdrop, seat: slot, species: species,
            hasSpecies: true, reactor: sim.reactors[pad].name,
            hasReactor: true)
      else:
        if sim.hasMoleculeAt(cell):
          sim.cogs[slot].lastAction = acWait
          continue
        sim.placeMolecule(cell, species)
        sim.cogs[slot].hasCarry = false
        if cell == sim.cogs[slot].home:
          sim.cogs[slot].hoard.inc
        sim.emit GameEvent(kind: evDrop, seat: slot, species: species,
          hasSpecies: true, x: cell.x, y: cell.y, hasReactor: false)
    else:
      discard

# --------------------------------------------------------------------------
# Step 4 -- moves
# --------------------------------------------------------------------------

proc stepMoves(sim: var Sim) =
  var moved: array[MaxSeats, bool]
  for slot in 0 ..< Seats:
    let action = sim.cogs[slot].lastAction
    if action notin {acMoveN, acMoveS, acMoveE, acMoveW}:
      continue
    var direction = 0
    for index, candidate in StepAction:
      if candidate == action:
        direction = index
    let target = sim.cogs[slot].cell.neighbour(direction)
    if sim.room.isWall(target):
      sim.cogs[slot].lastAction = acWait
      continue
    ## Against the LIVE board: a move into a cell a lower-numbered seat has
    ## already moved into this tick fails and degrades to wait.
    var blocked = false
    for other in 0 ..< Seats:
      if other != slot and sim.cogs[other].cell == target:
        blocked = true
    if blocked:
      sim.cogs[slot].lastAction = acWait
      continue
    sim.cogs[slot].cell = target
    moved[slot] = true
  for slot in 0 ..< Seats:
    if moved[slot]:
      sim.cogs[slot].moveTimer = max(0, sim.config.moveCooldown - 1)
    elif sim.cogs[slot].moveTimer > 0:
      sim.cogs[slot].moveTimer.dec

# --------------------------------------------------------------------------
# Step 5 -- auto-eat
# --------------------------------------------------------------------------

proc stepEat(sim: var Sim) =
  for slot in 0 ..< Seats:
    let cell = sim.cogs[slot].cell
    if not sim.hasFoodAt(cell):
      continue
    sim.clearFood(cell)
    sim.cogs[slot].foodEaten.inc
    sim.cogs[slot].shiftEaten.inc
    sim.emit GameEvent(kind: evEat, seat: slot, x: cell.x, y: cell.y)

# --------------------------------------------------------------------------
# Step 6 -- reactions
# --------------------------------------------------------------------------

proc placeFoodTokens*(sim: var Sim, index, count, deliverer: int) =
  ## Newly produced tokens land on free spill-ring cells ordered by Manhattan
  ## distance to the cog that delivered the triggering molecule (ties by
  ## (row, col)), so a supplier's work pays out at its own feet.
  let anchor =
    if deliverer >= 0 and deliverer < Seats: sim.cogs[deliverer].cell
    else: sim.reactors[index].cell
  var free: seq[Cell]
  for cell in sim.room.spill[index]:
    if not sim.hasFoodAt(cell):
      free.add cell
  free.sort(proc (a, b: Cell): int =
    let da = manhattan(a, anchor)
    let db = manhattan(b, anchor)
    if da != db: cmp(da, db)
    elif a.y != b.y: cmp(a.y, b.y)
    else: cmp(a.x, b.x))
  var placed = 0
  for cell in free:
    if placed >= count:
      break
    sim.placeFood(cell)
    inc placed
  sim.foodMade += placed
  sim.reactors[index].foodMade += placed
  sim.reactors[index].shiftFoodMade += placed
  if placed < count:
    sim.emit GameEvent(kind: evSpoil, reactor: sim.reactors[index].name,
      hasReactor: true, lost: count - placed)

proc stepReactions(sim: var Sim) =
  for index in 0 ..< sim.reactors.len:
    if sim.reactors[index].cooldown > 0:
      sim.reactors[index].cooldown.dec
    sim.reactors[index].ticksSinceReaction.inc
    let deliverer = sim.reactors[index].lastDeliverer
    if sim.reactors[index].charge == 0:
      ## Cold start: six deliveries of pure investment, no food.
      let cost = sim.config.coldStartCost
      if sim.reactors[index].stock[0] >= cost and
          sim.reactors[index].stock[1] >= cost:
        sim.reactors[index].stock[0] -= cost
        sim.reactors[index].stock[1] -= cost
        sim.reactors[index].charge = 1
        sim.reactors[index].ticksSinceReaction = 0
        sim.coldStarts.inc
        sim.emit GameEvent(kind: evRestart, reactor: sim.reactors[index].name,
          hasReactor: true, by: deliverer)
        sim.addBeat("restart", reactor = $sim.reactors[index].name)
      continue
    if sim.reactors[index].cooldown > 0:
      continue
    if sim.reactors[index].stock[0] < 1 or sim.reactors[index].stock[1] < 1:
      continue
    sim.reactors[index].stock[0].dec
    sim.reactors[index].stock[1].dec
    sim.reactors[index].charge =
      min(sim.config.chargeMax, sim.reactors[index].charge + 1)
    sim.reactors[index].cooldown = sim.config.reactionCooldown
    sim.reactors[index].ticksSinceReaction = 0
    sim.reactors[index].reactions.inc
    sim.reactors[index].shiftReactions.inc
    let produced = 1 + sim.reactors[index].charge div 3
    sim.emit GameEvent(kind: evReact, reactor: sim.reactors[index].name,
      hasReactor: true, charge: sim.reactors[index].charge,
      foodYield: produced, by: deliverer)
    sim.placeFoodTokens(index, produced, deliverer)

# --------------------------------------------------------------------------
# Step 7 -- charge decay
# --------------------------------------------------------------------------

proc stepDecay(sim: var Sim) =
  if sim.tick <= 0 or sim.tick mod sim.config.chargeDecayPeriod != 0:
    return
  for index in 0 ..< sim.reactors.len:
    if sim.reactors[index].charge <= 0:
      continue
    sim.reactors[index].charge.dec
    if sim.reactors[index].charge == 0:
      sim.emit GameEvent(kind: evCold, reactor: sim.reactors[index].name,
        hasReactor: true)
      sim.addBeat("cold", reactor = $sim.reactors[index].name)

# --------------------------------------------------------------------------
# Step 8 -- food rot
# --------------------------------------------------------------------------

proc stepRot(sim: var Sim) =
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      if sim.foodGrid[y][x] < 0:
        continue
      sim.foodGrid[y][x].inc
      if sim.foodGrid[y][x] >= sim.config.foodLifetime:
        sim.foodGrid[y][x] = -1
        sim.foodRotted.inc
        sim.emit GameEvent(kind: evRot, x: x, y: y)

# --------------------------------------------------------------------------
# Step 9 -- record
# --------------------------------------------------------------------------

proc stepRecord(sim: var Sim) =
  sim.frames.add sim.buildFrame()
  var row = @[sim.tick]
  for reactor in sim.reactors:
    row.add reactor.charge
  sim.chargeSeries.add row

# --------------------------------------------------------------------------
# End conditions
# --------------------------------------------------------------------------

proc endGame*(sim: var Sim, reason: EndReason, ending: EndingKind) =
  if sim.done:
    return
  sim.done = true
  sim.phase = GameOver
  sim.reason = reason
  sim.ending = ending
  var scores: seq[int]
  for slot in 0 ..< Seats:
    scores.add sim.cogs[slot].foodEaten
  sim.emit GameEvent(kind: evEnd, reason: reason, ending: ending,
    scores: scores)
  sim.addBeat("gameover")

proc endEarly*(sim: var Sim) =
  ## The play deadline fired between shifts: score what was played and settle.
  sim.endGame(erDeadline, ekDeadline)

proc forfeit*(sim: var Sim) =
  ## No seat connected within playerConnectTimeoutSeconds. Scores are all
  ## zero; results and the replay are still written.
  for slot in 0 ..< Seats:
    sim.cogs[slot].foodEaten = 0
  sim.endGame(erForfeit, ekForfeit)

proc closeShift(sim: var Sim) =
  sim.shift.inc
  var record = ShiftRecord(shift: sim.shift)
  for index in 0 ..< sim.reactors.len:
    record.reactions.add sim.reactors[index].shiftReactions
    record.foodMade.add sim.reactors[index].shiftFoodMade
    record.charge.add sim.reactors[index].charge
  var eaten: seq[int]
  var totalMisdrops = 0
  for slot in 0 ..< Seats:
    record.eaten[slot] = sim.cogs[slot].shiftEaten
    eaten.add sim.cogs[slot].shiftEaten
    totalMisdrops += sim.cogs[slot].misdrops
  ## Per-shift misdrops and cold starts are diffed from the running totals.
  var priorMisdrops = 0
  var priorColdStarts = 0
  for past in sim.history:
    priorMisdrops += past.misdrops
    priorColdStarts += past.coldStarts
  record.misdrops = totalMisdrops - priorMisdrops
  record.coldStarts = sim.coldStarts - priorColdStarts
  sim.history.add record

  sim.emit GameEvent(kind: evShift, shift: sim.shift,
    charges: record.charge, foodMade: record.foodMade, eaten: eaten,
    misdrops: record.misdrops, coldStarts: record.coldStarts)
  sim.addBeat("shift", n = sim.shift)

  for slot in 0 ..< Seats:
    sim.cogs[slot].shiftEaten = 0
  for index in 0 ..< sim.reactors.len:
    sim.reactors[index].shiftReactions = 0
    sim.reactors[index].shiftFoodMade = 0

  var allCold = true
  for reactor in sim.reactors:
    if reactor.charge > 0:
      allCold = false
  if allCold: sim.coldStreak.inc else: sim.coldStreak = 0

  if sim.shift >= sim.config.shifts:
    sim.endGame(erComplete, ekShiftLimit)
    return
  if sim.coldStreak >= FamineShifts and sim.foodCells().len == 0:
    if not sim.famineLatched:
      sim.famineLatched = true
      sim.emit GameEvent(kind: evFamine)
      sim.addBeat("famine")
    sim.endGame(erComplete, ekFamine)

proc stepTick*(sim: var Sim) =
  ## One tick, in the nine numbered steps. Returns with the tick recorded and
  ## the shift accounting closed when the tick landed on a shift boundary.
  if sim.done:
    return
  sim.phase = Playing
  sim.tick.inc
  sim.stepVents()
  sim.stepIntent()
  sim.stepTakeDrop()
  sim.stepMoves()
  sim.stepEat()
  sim.stepReactions()
  sim.stepDecay()
  sim.stepRot()
  sim.stepRecord()
  if sim.tick mod sim.config.ticksPerShift == 0:
    sim.closeShift()

proc runShift*(sim: var Sim) =
  ## Ticks until the next shift boundary (or until the episode ends).
  let target = ((sim.tick div sim.config.ticksPerShift) + 1) *
    sim.config.ticksPerShift
  while not sim.done and sim.tick < target:
    sim.stepTick()

# --------------------------------------------------------------------------
# Orders
# --------------------------------------------------------------------------

proc lowestChargeReactor(sim: Sim): ReactorName =
  ## The clamp target the design names for a reactor absent in this variant:
  ## the present reactor with the lowest charge.
  var best = 0
  var bestCharge = high(int)
  for index in 0 ..< sim.reactors.len:
    if sim.reactors[index].charge < bestCharge:
      bestCharge = sim.reactors[index].charge
      best = index
  sim.reactors[best].name

proc normalizeOrder*(sim: Sim, order: Order):
    tuple[ok: bool, order: Order, error: string] =
  ## Validates one standing order against THIS variant and clamps the one
  ## thing the design says is clampable (an absent reactor, on `supply` and on
  ## `forage` alike). Everything else is an invalid reply -- including a
  ## species whose vent is absent here. A feedstock the named reactor does not
  ## take is ACCEPTED as written: the misdrop is the graph test and must stay
  ## expressible.
  var normalized = order
  normalized.clamped = false
  case order.job
  of jobIdle:
    normalized.hasMolecule = false
    normalized.hasReactor = false
  of jobForage:
    normalized.hasMolecule = false
    if order.hasReactor and not sim.config.hasReactor(order.reactor):
      ## Clamped, not silently dropped: the seat named a vat, and the `order`
      ## event has to say the room moved it.
      normalized.reactor = sim.lowestChargeReactor()
      normalized.hasReactor = true
      normalized.clamped = true
  of jobSupply, jobHoard:
    if not order.hasMolecule:
      return (false, normalized, "job " & $order.job & " needs a molecule")
    if not sim.config.hasSpecies(order.molecule):
      return (false, normalized,
        $order.molecule & " does not exist in this variant")
    if order.job == jobSupply:
      if not order.hasReactor:
        return (false, normalized, "job supply needs a reactor")
      if not sim.config.hasReactor(order.reactor):
        ## Clamped to the present reactor with the lowest charge.
        normalized.reactor = sim.lowestChargeReactor()
        normalized.hasReactor = true
        normalized.clamped = true
    else:
      normalized.hasReactor = false
  normalized.say = sayText(normalized.say)
  normalized.notes = notesText(normalized.notes)
  (true, normalized, "")

proc applyOrder*(sim: var Sim, slot: int, order: Order) =
  ## Installs one seat's standing order for the shift about to be played and
  ## records the `order` event the feed and the replay read.
  let normalized = sim.normalizeOrder(order)
  var final =
    if normalized.ok: normalized.order
    else: sim.courierOrder(slot)
  if not normalized.ok:
    final.source = osFallback
  sim.cogs[slot].lastOrder = sim.cogs[slot].order
  sim.cogs[slot].order = final
  sim.cogs[slot].hasOrder = true
  sim.cogs[slot].say = final.say
  if final.notes.len > 0:
    sim.cogs[slot].notes = final.notes
  sim.emit GameEvent(kind: evOrder, seat: slot, shift: sim.shift + 1,
    job: final.job, species: final.molecule, hasSpecies: final.hasMolecule,
    reactor: final.reactor, hasReactor: final.hasReactor,
    source: final.source, clamped: final.clamped, say: final.say,
    notes: final.notes, latencyMs: final.latencyMs)

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  ## `names` are POLICY names (platform side); aliases go to the players and
  ## into the replay's `names[]`. Arrays indexed by slot, always length 8.
  var names = newJArray()
  var aliases = newJArray()
  var scores = newJArray()
  var win = newJArray()
  var foodEaten = newJArray()
  var delivered = newJArray()
  var misdrops = newJArray()
  var hoarded = newJArray()
  var best = 0
  for slot in 0 ..< Seats:
    best = max(best, sim.cogs[slot].foodEaten)
  for slot in 0 ..< Seats:
    names.add(%sim.policyNames[slot])
    aliases.add(%sim.cogs[slot].alias)
    scores.add(%sim.cogs[slot].foodEaten)
    win.add(%(sim.cogs[slot].foodEaten == best))
    foodEaten.add(%sim.cogs[slot].foodEaten)
    delivered.add(%sim.cogs[slot].delivered)
    misdrops.add(%sim.cogs[slot].misdrops)
    hoarded.add(%sim.cogs[slot].hoard)
  var reactions = newJArray()
  for reactor in sim.reactors:
    reactions.add(%reactor.reactions)
  %*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "food_eaten": foodEaten,
    "delivered": delivered,
    "misdrops": misdrops,
    "hoarded": hoarded,
    "reactions": reactions,
    "food_made": sim.foodMade,
    "food_rotted": sim.foodRotted,
    "cold_starts": sim.coldStarts,
    "shifts": sim.shift,
    "reason": $sim.reason,
    "ending": $sim.ending
  }
