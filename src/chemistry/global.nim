## The board renderer: Bitworld sprite-protocol v1 emission for the spectator
## socket and the static wasm replay viewer.
##
## Heavily reduced fork of `coworld-ctf/src/ctf/global.nim`. Kept: the
## sprite-protocol emitter, layer/object pooling, the chrome `TextMessage`
## smuggling on the reserved 1x1 sprite, and the board-render scale helper.
## DELETED: fog-of-war/FOV, the first-person PiP, articulated rig art, the
## grenade/spray/shield/barrier families, endzone bakes, perks and handicaps.

import std/[math, os, strutils, tables]
import pixie
import bitworld/spriteprotocol
import sim_types, sim_config, room, sim_state

const
  MapLayerId* = 0
  BackgroundSpriteId = 40
  BackgroundObjectId = 40
  VatSpriteBase = 200
  VentSpriteBase = 220
  MoleculeSpriteBase = 230
  FoodSpriteId = 240
  FoodPulseSpriteId = 241
  FlashSpriteId = 242
  CogSpriteBase = 250
  CogCarrySpriteBase = 258
  LabelSpriteBase = 270
  VatObjectBase = 100
  VentObjectBase = 110
  MoleculeObjectBase = 300
  FoodObjectBase = 600
  CogObjectBase = 800
  CarryObjectBase = 820
  LabelObjectBase = 840
  FlashObjectBase = 860
  MoleculeObjectCap = 260
  FoodObjectCap = 160
  FoodPulseTicks = 48

type
  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    sentSprites*: seq[int]
    chromeSent*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool

  BoardArt = object
    loaded: bool
    background: tuple[width, height: int, pixels: seq[uint8]]
    vats: Table[int, tuple[width, height: int, pixels: seq[uint8]]]
    vents: Table[int, tuple[width, height: int, pixels: seq[uint8]]]
    molecules: Table[int, tuple[width, height: int, pixels: seq[uint8]]]
    food: tuple[width, height: int, pixels: seq[uint8]]
    foodPulse: tuple[width, height: int, pixels: seq[uint8]]
    flash: tuple[width, height: int, pixels: seq[uint8]]
    cogs: Table[int, tuple[width, height: int, pixels: seq[uint8]]]
    labels: Table[int, tuple[width, height: int, pixels: seq[uint8]]]

var boardArt: BoardArt
var artVariantKey = ""

proc initGlobalViewerState*(): GlobalViewerState =
  result.initialized = true
  result.replaySeekTick = -1
  result.mouseLayer = MapLayerId

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## Chemistry's board is authored at its final 1536x864, so the spectator
  ## stream never supersamples. Kept (and reported in the chrome frame as
  ## `bs`) because the viewer converts board px <-> world px through it.
  discard mapWidth
  discard mapHeight
  1

proc gameDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir, appDir / "..", ".", "/"]:
    if dirExists(candidate / "data"):
      return candidate
  "."

proc dataPath(name: string): string = gameDir() / "data" / name

proc imageToStraightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let color = image.data[i].rgba()
    result[i * 4] = color.r
    result[i * 4 + 1] = color.g
    result[i * 4 + 2] = color.b
    result[i * 4 + 3] = color.a

proc loadSprite(name: string):
    tuple[width, height: int, pixels: seq[uint8]] =
  let image = readImage(dataPath(name))
  (image.width, image.height, imageToStraightRgba(image))

proc blit(dst: var seq[uint8], dstW, dstH: int,
          src: openArray[uint8], srcW, srcH, atX, atY: int) =
  for y in 0 ..< srcH:
    let dy = atY + y
    if dy < 0 or dy >= dstH: continue
    for x in 0 ..< srcW:
      let dx = atX + x
      if dx < 0 or dx >= dstW: continue
      let srcOffset = (y * srcW + x) * 4
      let alpha = src[srcOffset + 3]
      if alpha == 0: continue
      let dstOffset = (dy * dstW + dx) * 4
      if alpha == 255:
        dst[dstOffset] = src[srcOffset]
        dst[dstOffset + 1] = src[srcOffset + 1]
        dst[dstOffset + 2] = src[srcOffset + 2]
        dst[dstOffset + 3] = 255
        continue
      let sa = alpha.float32 / 255.0
      for channel in 0 .. 2:
        dst[dstOffset + channel] = uint8(
          src[srcOffset + channel].float32 * sa +
          dst[dstOffset + channel].float32 * (1.0 - sa))
      dst[dstOffset + 3] = max(dst[dstOffset + 3], alpha)

var typefaceCache: Typeface

proc boardTypeface(): Typeface =
  if typefaceCache.isNil:
    typefaceCache = readTypeface(dataPath("font.ttf"))
  typefaceCache

proc textSprite(text: string, r, g, b: uint8):
    tuple[width, height: int, pixels: seq[uint8]] =
  ## The alias under a cog's feet, vector type with a dark drop shadow so it
  ## stays legible over the lab floor.
  let font = newFont(boardTypeface())
  font.size = 15
  font.lineHeight = 18
  let width = max(8, int(ceil(font.layoutBounds(text).x)) + 6)
  var image = newImage(width, 20)
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(0, 0, 0, 0.75)
  image.fillText(font, text, translate(vec2(4, 2)))
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(r.float32 / 255, g.float32 / 255, b.float32 / 255, 1)
  image.fillText(font, text, translate(vec2(3, 1)))
  (image.width, image.height, imageToStraightRgba(image))

proc colorSlug*(name: string): string =
  name.replace(" ", "").toLowerAscii()

proc bakeBackground(config: GameConfig, room: Room):
    tuple[width, height: int, pixels: seq[uint8]] =
  ## The whole board's static ground: lab floor, the wall ring and the two
  ## pillars, the reactor pads and the eight home plates. Emitted ONCE per
  ## viewer as object id 40 at z = -32768, which is exactly the window
  ## `client/broadcast_core.js` caches as a static band.
  let floorTile = loadSprite("floor.png")
  let wallTile = loadSprite("wall.png")
  let padTile = loadSprite("pad.png")
  let homeTile = loadSprite("home.png")
  var pixels = newSeq[uint8](BoardW * BoardH * 4)
  for y in 0 ..< RoomRows:
    for x in 0 ..< RoomCols:
      let cell = Cell(x: x, y: y)
      let tile = if room.isWall(cell): wallTile else: floorTile
      blit(pixels, BoardW, BoardH, tile.pixels, tile.width, tile.height,
        x * CellPx, y * CellPx)
  for index in 0 ..< room.reactors.len:
    for cell in room.pad[index]:
      blit(pixels, BoardW, BoardH, padTile.pixels, padTile.width,
        padTile.height, cell.x * CellPx, cell.y * CellPx)
  for home in SeatHomes:
    blit(pixels, BoardW, BoardH, homeTile.pixels, homeTile.width,
      homeTile.height, home.x * CellPx, home.y * CellPx)
  discard config
  (BoardW, BoardH, pixels)

proc ensureArt*(config: GameConfig, room: Room, names, colors: seq[string]) =
  ## Bakes every board sprite once per process. The variant key covers the
  ## things that change the ground bake (which reactors exist) so a second
  ## episode in one process cannot inherit the first one's board.
  let key = config.variantId() & "|" & names.join(",") & "|" & colors.join(",")
  if boardArt.loaded and artVariantKey == key:
    return
  boardArt = BoardArt()
  artVariantKey = key
  boardArt.background = bakeBackground(config, room)
  for index, reactor in room.reactors:
    for state in 0 .. 2:
      boardArt.vats[index * 4 + state] =
        loadSprite("vat_" & $reactor & "_" & $state & ".png")
  for species in config.speciesPresent():
    boardArt.vents[species.speciesId()] =
      loadSprite("vent_" & $species & ".png")
    boardArt.molecules[species.speciesId()] =
      loadSprite("mol_" & $species & ".png")
  boardArt.food = loadSprite("food.png")
  boardArt.foodPulse = loadSprite("food_ripe.png")
  boardArt.flash = loadSprite("flash.png")
  for slot in 0 ..< Seats:
    let slug = colorSlug(
      if slot < colors.len: colors[slot] else: SeatColors[slot])
    boardArt.cogs[slot] = loadSprite("cog_" & slug & "_front.png")
    boardArt.cogs[Seats + slot] = loadSprite("cog_" & slug & "_carry.png")
    boardArt.labels[slot] = textSprite(
      (if slot < names.len: names[slot] else: SeatAliases[slot]).toUpperAscii(),
      240, 232, 216)
  boardArt.loaded = true

proc addSpriteOnce(
  packet: var seq[uint8],
  state: var GlobalViewerState,
  spriteId: int,
  sprite: tuple[width, height: int, pixels: seq[uint8]],
  label: string
) =
  if spriteId in state.sentSprites:
    return
  state.sentSprites.add spriteId
  packet.addSprite(spriteId, sprite.width, sprite.height, sprite.pixels, label)

proc vatState(charge, chargeMax: int): int =
  if charge <= 0: 0
  elif charge * 2 <= chargeMax: 1
  else: 2

type
  BoardInput* = object
    ## Everything one drawn frame needs. Built by the replay viewer from a
    ## recorded frame and by the live server from the sim.
    config*: GameConfig
    room*: Room
    names*: seq[string]
    colors*: seq[string]
    frame*: Frame

proc buildBoardPacket*(
  input: BoardInput,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## One retained-mode board update: layer + viewport (restated every frame,
  ## the client ignores an unchanged one), every visible object, and a delete
  ## for every object that has gone.
  nextState = state
  if not nextState.initialized:
    nextState = initGlobalViewerState()
  ensureArt(input.config, input.room, input.names, input.colors)

  result.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
  result.addViewport(MapLayerId, BoardW, BoardH)

  var live: seq[int]

  proc place(packet: var seq[uint8], objectId, x, y, z, spriteId: int) =
    packet.addObject(objectId, x, y, z, MapLayerId, spriteId)
    live.add objectId

  addSpriteOnce(result, nextState, BackgroundSpriteId, boardArt.background,
    "board")
  result.place(BackgroundObjectId, 0, 0, -32768, BackgroundSpriteId)

  for species in input.config.speciesPresent():
    let id = species.speciesId()
    addSpriteOnce(result, nextState, VentSpriteBase + id,
      boardArt.vents[id], "vent " & $species)
    let cell = VentCells[species]
    result.place(VentObjectBase + id, cell.x * CellPx, cell.y * CellPx,
      -300, VentSpriteBase + id)

  for index in 0 ..< input.room.reactors.len:
    let base = index * 4
    let charge =
      if base < input.frame.reactors.len: input.frame.reactors[base] else: 0
    let state = vatState(charge, input.config.chargeMax)
    let spriteId = VatSpriteBase + index * 4 + state
    addSpriteOnce(result, nextState, spriteId, boardArt.vats[index * 4 + state],
      "vat " & $input.room.reactors[index] & " " & $state)
    let centre = ReactorCells[input.room.reactors[index]]
    result.place(VatObjectBase + index, (centre.x - 1) * CellPx,
      (centre.y - 1) * CellPx, -200, spriteId)
    ## A vat whose cooldown is at its ceiling reacted on THIS tick: flash it.
    ## Derived from the recorded frame, so a seek shows the same flash the
    ## live board did.
    let cooldown =
      if base + 3 < input.frame.reactors.len: input.frame.reactors[base + 3]
      else: 0
    if cooldown >= input.config.reactionCooldown and
        input.config.reactionCooldown > 0:
      addSpriteOnce(result, nextState, FlashSpriteId, boardArt.flash, "flash")
      result.place(FlashObjectBase + index, (centre.x - 1) * CellPx,
        (centre.y - 1) * CellPx, -190, FlashSpriteId)

  var foodIndex = 0
  var moleculeIndex = 0
  var i = 0
  while i + 2 < input.frame.food.len and foodIndex < FoodObjectCap:
    let x = input.frame.food[i]
    let y = input.frame.food[i + 1]
    let ttl = input.frame.food[i + 2]
    let ripe = ttl <= FoodPulseTicks
    let spriteId = if ripe: FoodPulseSpriteId else: FoodSpriteId
    addSpriteOnce(result, nextState, spriteId,
      (if ripe: boardArt.foodPulse else: boardArt.food), "food")
    result.place(FoodObjectBase + foodIndex, x * CellPx + 8, y * CellPx + 8,
      -150, spriteId)
    inc foodIndex
    i += 3
  i = 0
  while i + 2 < input.frame.molecules.len and moleculeIndex < MoleculeObjectCap:
    let x = input.frame.molecules[i]
    let y = input.frame.molecules[i + 1]
    let id = input.frame.molecules[i + 2]
    if boardArt.molecules.hasKey(id):
      addSpriteOnce(result, nextState, MoleculeSpriteBase + id,
        boardArt.molecules[id], "molecule " & $speciesFromId(id))
      result.place(MoleculeObjectBase + moleculeIndex, x * CellPx + 8,
        y * CellPx + 8, -100, MoleculeSpriteBase + id)
      inc moleculeIndex
    i += 3

  for slot in 0 ..< Seats:
    let base = slot * 4
    if base + 3 >= input.frame.cogs.len:
      break
    let x = input.frame.cogs[base]
    let y = input.frame.cogs[base + 1]
    let carry = input.frame.cogs[base + 2]
    let spriteId =
      if carry >= 0: CogCarrySpriteBase + slot else: CogSpriteBase + slot
    addSpriteOnce(result, nextState, spriteId,
      boardArt.cogs[(if carry >= 0: Seats + slot else: slot)],
      "cog " & (if slot < input.names.len: input.names[slot]
                else: SeatAliases[slot]))
    let px = x * CellPx
    let py = y * CellPx
    result.place(CogObjectBase + slot, px, py, py, spriteId)
    if carry >= 0 and boardArt.molecules.hasKey(carry):
      addSpriteOnce(result, nextState, MoleculeSpriteBase + carry,
        boardArt.molecules[carry], "molecule " & $speciesFromId(carry))
      result.place(CarryObjectBase + slot, px + 8, py - 22, py + 1,
        MoleculeSpriteBase + carry)
    if input.config.showPlayerLabels:
      addSpriteOnce(result, nextState, LabelSpriteBase + slot,
        boardArt.labels[slot], "label " & $slot)
      let label = boardArt.labels[slot]
      result.place(LabelObjectBase + slot,
        px + CellPx div 2 - label.width div 2, py + CellPx - 4, py + 2,
        LabelSpriteBase + slot)

  for objectId in state.objectIds:
    if objectId notin live:
      result.addDeleteObject(objectId)
  nextState.objectIds = live

proc addChromeFrame*(packet: var seq[uint8], chrome: string) =
  ## The broadcast chrome rides the label of the reserved 1x1 sprite id 4090,
  ## which `client/broadcast_core.js` routes to onText and never draws. This
  ## binary path is the only one that survives a hosted replay.
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chrome)

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState,
  message: string
) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands (`s:<tick>`) are intercepted before the char-by-char transport
  ## path so a multi-digit tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = (if item.hasLayer: item.layer else: MapLayerId)
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick =
          try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        discard
      else:
        for character in item.text:
          state.replayCommands.add character
    else:
      discard
