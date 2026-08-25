## The courier kernel: one standing order in, one grid action per tick out.
##
## A seat submits ONE order per shift (`## Decisions` in the design note) and
## this deterministic kernel walks it for the whole 60-tick shift, so the sim's
## policy interface stays per-tick grid actions while an LLM only ever chooses
## a job. Planning is a multi-source BFS over floor cells expanded N, E, S, W
## (other cogs are NOT obstacles for planning); the move itself is blocked by
## another cog, so the descent picks the best neighbour that is actually free.

import sim_types, room, sim_state

proc bestForageReactor(sim: Sim, order: Order): int =
  ## The named reactor when it is present, else the live reactor with the
  ## highest charge, ties by reactor order amber, beryl, cobalt.
  if order.hasReactor:
    let index = sim.room.reactorIndex(order.reactor)
    if index >= 0:
      return index
  var best = 0
  var bestCharge = -1
  for index in 0 ..< sim.reactors.len:
    if sim.reactors[index].charge > bestCharge:
      bestCharge = sim.reactors[index].charge
      best = index
  best

proc supplyReactor(sim: Sim, order: Order): int =
  if order.hasReactor:
    let index = sim.room.reactorIndex(order.reactor)
    if index >= 0:
      return index
  ## An order naming an absent reactor is clamped before it ever reaches the
  ## kernel; this is the belt-and-braces path.
  var best = 0
  var bestCharge = high(int)
  for index in 0 ..< sim.reactors.len:
    if sim.reactors[index].charge < bestCharge:
      bestCharge = sim.reactors[index].charge
      best = index
  best

proc occupied(sim: Sim, slot: int, cell: Cell): bool =
  for other in 0 ..< Seats:
    if other != slot and sim.cogs[other].cell == cell:
      return true
  false

proc walk(sim: Sim, slot: int, targets: openArray[Cell]):
    tuple[arrived: bool, action: Action] =
  ## One step down the distance gradient toward the nearest target. `arrived`
  ## when the cog already stands on one. A cog whose only descending
  ## neighbour is occupied waits this tick rather than walking away from the
  ## job -- the blocker is itself walking, so the queue clears.
  if targets.len == 0:
    return (false, acWait)
  let field = sim.room.distanceField(targets)
  let cell = sim.cogs[slot].cell
  let here = field.distanceTo(cell)
  if here == 0:
    return (true, acWait)
  if here < 0:
    return (false, acWait)
  var bestDirection = -1
  var bestDistance = here
  var sidestep = -1
  for direction in 0 .. 3:
    let next = cell.neighbour(direction)
    if sim.room.isWall(next) or sim.occupied(slot, next):
      continue
    let distance = field.distanceTo(next)
    if distance < 0:
      continue
    if distance < bestDistance:
      bestDistance = distance
      bestDirection = direction
    elif distance == here and sidestep < 0:
      sidestep = direction
  if bestDirection >= 0:
    return (false, StepAction[bestDirection])
  ## Every descending neighbour is a wall or another cog. Take an
  ## equal-distance step instead of standing still: two cogs whose only
  ## improving step is each other's cell would otherwise stall forever, and a
  ## stalled courier is a lane nobody serves.
  if sidestep >= 0:
    return (false, StepAction[sidestep])
  (false, acWait)

proc offPadStep(sim: Sim, slot: int): Action =
  ## First legal of N, E, S, W that leaves every reactor pad and can actually
  ## take a dropped molecule.
  let cell = sim.cogs[slot].cell
  for direction in 0 .. 3:
    let next = cell.neighbour(direction)
    if sim.room.isFloor(next) and sim.room.padAt(next) < 0 and
        not sim.hasMoleculeAt(next) and not sim.occupied(slot, next):
      return StepAction[direction]
  acWait

proc ventApproachCells(sim: Sim, species: Species): seq[Cell] =
  let vent = VentCells[species]
  for direction in 0 .. 3:
    let cell = vent.neighbour(direction)
    if sim.room.isFloor(cell) and not sim.hasMoleculeAt(cell):
      result.add cell

proc kernelAction*(sim: Sim, slot: int): Action =
  ## This tick's action for one seat, from its standing order and the state as
  ## it stands at step 2 of the tick resolution order.
  let cog = sim.cogs[slot]
  let order = cog.order

  case order.job
  of jobIdle:
    result = acWait
  of jobForage:
    let food = sim.foodCells()
    if food.len > 0:
      ## Standing on a token IS the action -- eating is automatic at step 5.
      let step = sim.walk(slot, food)
      return (if step.arrived: acWait else: step.action)
    let index = sim.bestForageReactor(order)
    let step = sim.walk(slot, sim.room.spill[index])
    result = (if step.arrived: acWait else: step.action)
  of jobSupply, jobHoard:
    if not order.hasMolecule:
      return acWait
    let wanted = order.molecule
    if cog.hasCarry and cog.carrying == wanted:
      let targets =
        if order.job == jobHoard: @[cog.home]
        else: sim.room.pad[sim.supplyReactor(order)]
      let step = sim.walk(slot, targets)
      return (if step.arrived: acDrop else: step.action)
    if cog.hasCarry:
      ## Holding the wrong molecule: put it down somewhere it cannot be
      ## absorbed, stepping off a pad first.
      if sim.room.padAt(cog.cell) >= 0 or sim.hasMoleculeAt(cog.cell):
        return sim.offPadStep(slot)
      return acDrop
    let loose = sim.looseCells(wanted)
    if loose.len > 0:
      let step = sim.walk(slot, loose)
      return (if step.arrived: acTake else: step.action)
    let approach = sim.ventApproachCells(wanted)
    if approach.len == 0:
      return acWait
    let step = sim.walk(slot, approach)
    result = (if step.arrived: acWait else: step.action)
