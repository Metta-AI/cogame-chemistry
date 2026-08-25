## The Chemistry room: one authored 32x18 grid per variant, plus the BFS the
## courier kernel walks.
##
## Heavily reduced fork of `coworld-ctf/src/ctf/arena.nim`. Everything the CTF
## arena carried for procedural terrain -- the generator, mapSpec, symmetry,
## the validators, the pixel queries and `map_pool` -- is DELETED: Chemistry
## has one authored room per variant, so geometry is a pure function of the
## config and never of the seed.

import sim_types, sim_config

type
  Room* = object
    wall*: array[RoomRows, array[RoomCols, bool]]
    padOf*: array[RoomRows, array[RoomCols, int]]  ## reactor index, or -1
    reactors*: seq[ReactorName]
    spill*: seq[seq[Cell]]     ## per reactor, the 12-cell spill ring
    pad*: seq[seq[Cell]]       ## per reactor, the 3x3 pad
    vents*: seq[Vent]

proc inBounds*(cell: Cell): bool =
  cell.x >= 0 and cell.x < RoomCols and cell.y >= 0 and cell.y < RoomRows

proc isWall*(room: Room, cell: Cell): bool =
  if not cell.inBounds():
    return true
  room.wall[cell.y][cell.x]

proc isFloor*(room: Room, cell: Cell): bool =
  not room.isWall(cell)

proc buildRoom*(config: GameConfig): Room =
  ## The authored room. Walls are the full border ring plus two 2x2 pillars;
  ## everything else is floor. Reactor pads are floor -- a cog stands on the
  ## pad to drop into it.
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      result.padOf[y][x] = -1
      result.wall[y][x] =
        y == 0 or y == RoomRows - 1 or x == 0 or x == RoomCols - 1
  for cell in PillarCells:
    result.wall[cell.y][cell.x] = true

  result.reactors = config.reactorsPresent()
  for index, name in result.reactors:
    let centre = ReactorCells[name]
    var padCells: seq[Cell]
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let cell = Cell(x: centre.x + dx, y: centre.y + dy)
        result.padOf[cell.y][cell.x] = index
        padCells.add cell
    result.pad.add padCells
    ## The spill ring: the 5x5 border around the pad MINUS its four diagonal
    ## corners -- the 12 floor cells orthogonally or diagonally surrounding
    ## the pad. Ordered by (row, col) so the placement tiebreak is fixed.
    var ring: seq[Cell]
    for dy in -2 .. 2:
      for dx in -2 .. 2:
        let far = max(abs(dx), abs(dy))
        let near = min(abs(dx), abs(dy))
        if far != 2 or near == 2:
          continue
        let cell = Cell(x: centre.x + dx, y: centre.y + dy)
        if cell.inBounds() and not result.wall[cell.y][cell.x]:
          ring.add cell
    result.spill.add ring

  for species in config.speciesPresent():
    result.vents.add Vent(
      species: species,
      cell: VentCells[species],
      inert: species.isInert())

proc reactorIndex*(room: Room, name: ReactorName): int =
  for index, present in room.reactors:
    if present == name:
      return index
  -1

proc padAt*(room: Room, cell: Cell): int =
  if not cell.inBounds(): -1
  else: room.padOf[cell.y][cell.x]

const StepOrder*: array[4, Cell] = [
  Cell(x: 0, y: -1),   ## N
  Cell(x: 1, y: 0),    ## E
  Cell(x: 0, y: 1),    ## S
  Cell(x: -1, y: 0)]   ## W

const StepAction*: array[4, Action] = [acMoveN, acMoveE, acMoveS, acMoveW]

proc neighbour*(cell: Cell, direction: int): Cell =
  Cell(x: cell.x + StepOrder[direction].x, y: cell.y + StepOrder[direction].y)

type
  DistField* = object
    ## Multi-source breadth-first distance to the NEAREST of a target set,
    ## over floor cells, expanded in N, E, S, W order. The kernel walks it by
    ## gradient descent, so a path is a pure function of the room and the
    ## targets -- unique and deterministic, exactly as the design note
    ## requires. Other cogs are not obstacles HERE (planning); they are
    ## obstacles for the move itself, which `kernel.nim` applies when it picks
    ## the descending neighbour.
    dist*: array[RoomRows, array[RoomCols, int]]
    ok*: bool

proc distanceField*(room: Room, targets: openArray[Cell]): DistField =
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      result.dist[y][x] = -1
  var queue: seq[Cell]
  for target in targets:
    if not target.inBounds() or room.wall[target.y][target.x]:
      continue
    if result.dist[target.y][target.x] >= 0:
      continue
    result.dist[target.y][target.x] = 0
    result.ok = true
    queue.add target
  var head = 0
  while head < queue.len:
    let cell = queue[head]
    inc head
    let base = result.dist[cell.y][cell.x]
    for direction in 0 .. 3:
      let next = cell.neighbour(direction)
      if not next.inBounds() or room.wall[next.y][next.x]:
        continue
      if result.dist[next.y][next.x] >= 0:
        continue
      result.dist[next.y][next.x] = base + 1
      queue.add next

proc distanceTo*(field: DistField, cell: Cell): int =
  if not cell.inBounds(): -1 else: field.dist[cell.y][cell.x]
