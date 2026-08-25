## GameConfig lifecycle for Chemistry.
##
## Forked from `coworld-ctf/src/ctf/sim_config.nim`: defaults, the runtime
## JSON overlay (`config.update`) and validation. The field list IS the
## `game.config_schema` in `coworld_manifest_template.json`; a field added
## here without a schema entry is rejected by `coworld certify`, and
## `tests/test_manifest.nim` asserts the two agree.

import std/[json, strutils]
import sim_types

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    numAgents*: int
    seed*: int
    cycles*: int
    shifts*: int
    ticksPerShift*: int
    moveCooldown*: int
    carryCap*: int
    ventPeriod*: int
    ventGroundCap*: int
    distractorPeriod*: int
    distractorGroundCap*: int
    chargeMax*: int
    charge0*: int
    chargeDecayPeriod*: int
    reactionCooldown*: int
    coldStartCost*: int
    foodLifetime*: int
    llmTimeoutSeconds*: int
    minTurnSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int
    showPlayerLabels*: bool

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    numAgents: Seats,
    seed: 0,
    cycles: DefaultCycles,
    shifts: DefaultShifts,
    ticksPerShift: DefaultTicksPerShift,
    moveCooldown: DefaultMoveCooldown,
    carryCap: DefaultCarryCap,
    ventPeriod: DefaultVentPeriod,
    ventGroundCap: DefaultVentGroundCap,
    distractorPeriod: DefaultDistractorPeriod,
    distractorGroundCap: DefaultDistractorGroundCap,
    chargeMax: DefaultChargeMax,
    charge0: DefaultCharge0,
    chargeDecayPeriod: DefaultChargeDecayPeriod,
    reactionCooldown: DefaultReactionCooldown,
    coldStartCost: DefaultColdStartCost,
    foodLifetime: DefaultFoodLifetime,
    llmTimeoutSeconds: 20,
    minTurnSeconds: 18,
    maxOutputTokens: 700,
    model: "claude-haiku-4-5",
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 180,
    shutdownGraceSeconds: 20,
    showPlayerLabels: true
  )

proc variantId*(config: GameConfig): string =
  ## The variant name the observation and the replay report. Derived from the
  ## rules rather than carried as its own config field, so a hand-edited
  ## fixture can never claim a variant it is not playing.
  if config.cycles <= 2:
    if config.distractorPeriod > 0: "two-cycles-distractors"
    else: "two-cycles"
  else:
    if config.distractorPeriod > 0: "three-cycles-plentiful-distractors"
    else: "three-cycles"

proc reactorsPresent*(config: GameConfig): seq[ReactorName] =
  ## amber, beryl in the two-cycle room; all three otherwise.
  if config.cycles <= 2: @[rxAmber, rxBeryl]
  else: @[rxAmber, rxBeryl, rxCobalt]

proc speciesPresent*(config: GameConfig): seq[Species] =
  result = @[spResin, spSpark, spBrine]
  if config.distractorPeriod > 0:
    result.add spGlitter
    result.add spQuartz

proc hasReactor*(config: GameConfig, name: ReactorName): bool =
  name in config.reactorsPresent()

proc hasSpecies*(config: GameConfig, species: Species): bool =
  species in config.speciesPresent()

proc clampInt(value, lo, hi: int): int =
  max(lo, min(hi, value))

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(ChemistryError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  if node.hasKey("num_agents"):
    config.numAgents = node["num_agents"].getInt(Seats)
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("cycles"):
    config.cycles = clampInt(node["cycles"].getInt(DefaultCycles), 2, 3)
  if node.hasKey("shifts"):
    config.shifts = clampInt(node["shifts"].getInt(DefaultShifts), 1, 24)
  if node.hasKey("ticksPerShift"):
    config.ticksPerShift =
      clampInt(node["ticksPerShift"].getInt(DefaultTicksPerShift), 10, 120)
  if node.hasKey("moveCooldown"):
    config.moveCooldown =
      clampInt(node["moveCooldown"].getInt(DefaultMoveCooldown), 1, 8)
  if node.hasKey("carryCap"):
    config.carryCap = clampInt(node["carryCap"].getInt(DefaultCarryCap), 1, 2)
  if node.hasKey("ventPeriod"):
    config.ventPeriod =
      clampInt(node["ventPeriod"].getInt(DefaultVentPeriod), 1, 48)
  if node.hasKey("ventGroundCap"):
    config.ventGroundCap =
      clampInt(node["ventGroundCap"].getInt(DefaultVentGroundCap), 1, 24)
  if node.hasKey("distractorPeriod"):
    config.distractorPeriod =
      clampInt(node["distractorPeriod"].getInt(DefaultDistractorPeriod), 0, 64)
  if node.hasKey("distractorGroundCap"):
    config.distractorGroundCap = clampInt(
      node["distractorGroundCap"].getInt(DefaultDistractorGroundCap), 0, 64)
  if node.hasKey("chargeMax"):
    config.chargeMax =
      clampInt(node["chargeMax"].getInt(DefaultChargeMax), 1, 24)
  if node.hasKey("charge0"):
    config.charge0 = clampInt(node["charge0"].getInt(DefaultCharge0), 0, 24)
  if node.hasKey("chargeDecayPeriod"):
    config.chargeDecayPeriod = clampInt(
      node["chargeDecayPeriod"].getInt(DefaultChargeDecayPeriod), 1, 240)
  if node.hasKey("reactionCooldown"):
    config.reactionCooldown = clampInt(
      node["reactionCooldown"].getInt(DefaultReactionCooldown), 0, 48)
  if node.hasKey("coldStartCost"):
    config.coldStartCost =
      clampInt(node["coldStartCost"].getInt(DefaultColdStartCost), 1, 8)
  if node.hasKey("foodLifetime"):
    config.foodLifetime =
      clampInt(node["foodLifetime"].getInt(DefaultFoodLifetime), 24, 960)
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds =
      clampInt(node["llmTimeoutSeconds"].getInt(20), 5, 60)
  if node.hasKey("minTurnSeconds"):
    config.minTurnSeconds = clampInt(node["minTurnSeconds"].getInt(18), 0, 60)
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens =
      clampInt(node["maxOutputTokens"].getInt(700), 200, 2000)
  if node.hasKey("model"):
    config.model = node["model"].getStr(config.model)
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds =
      node["episodeTimeoutSeconds"].getInt(1200)
  if node.hasKey("playerConnectTimeoutSeconds"):
    config.playerConnectTimeoutSeconds =
      node["playerConnectTimeoutSeconds"].getInt(180)
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getInt(180)
  if node.hasKey("shutdownGraceSeconds"):
    config.shutdownGraceSeconds = node["shutdownGraceSeconds"].getInt(20)
  if node.hasKey("showPlayerLabels"):
    config.showPlayerLabels = node["showPlayerLabels"].getBool(true)

  if config.numAgents <= 0:
    config.numAgents = Seats
  config.numAgents = clampInt(config.numAgents, 1, Seats)
  ## Chemistry is an eight-seat game: the room, the lane arithmetic and the
  ## home cells are all built for eight. A smaller `num_agents` still runs
  ## (the missing seats simply never connect and never act), but the seat
  ## records always exist.
  while config.players.len < Seats:
    config.players.add(PlayerConfig(name: SeatAliases[config.players.len]))
  if config.players.len > Seats:
    config.players.setLen(Seats)
  if config.tokens.len > Seats:
    config.tokens.setLen(Seats)

proc configJson*(config: GameConfig): JsonNode =
  ## The `config` block the replay carries: every rule constant the viewer
  ## and any offline analysis needs, so the replay is self-sufficient.
  var reactors = newJArray()
  for name in config.reactorsPresent():
    var feeds = newJArray()
    for species in ReactorFeed[name]:
      feeds.add(%($species))
    reactors.add(%*{
      "name": $name,
      "cell": [ReactorCells[name].x, ReactorCells[name].y],
      "feedstocks": feeds
    })
  var vents = newJArray()
  for species in config.speciesPresent():
    vents.add(%*{
      "sp": $species,
      "cell": [VentCells[species].x, VentCells[species].y],
      "inert": species.isInert()
    })
  var homes = newJArray()
  for home in SeatHomes:
    homes.add(%*[home.x, home.y])
  result = %*{
    "variant": config.variantId(),
    "cols": RoomCols,
    "rows": RoomRows,
    "cell": CellPx,
    "shifts": config.shifts,
    "ticksPerShift": config.ticksPerShift,
    "cycles": config.reactorsPresent().len,
    "reactors": reactors,
    "vents": vents,
    "homes": homes,
    "chargeMax": config.chargeMax,
    "charge0": config.charge0,
    "chargeDecayPeriod": config.chargeDecayPeriod,
    "reactionCooldown": config.reactionCooldown,
    "coldStartCost": config.coldStartCost,
    "foodLifetime": config.foodLifetime,
    "moveCooldown": config.moveCooldown,
    "carryCap": config.carryCap,
    "ventPeriod": config.ventPeriod,
    "ventGroundCap": config.ventGroundCap,
    "distractorPeriod": config.distractorPeriod,
    "distractorGroundCap": config.distractorGroundCap,
    "showPlayerLabels": config.showPlayerLabels
  }

proc configFromJson*(node: JsonNode): GameConfig =
  ## Rebuilds a config from a replay's `config` block (viewer side).
  result = defaultGameConfig()
  result.shifts = node{"shifts"}.getInt(DefaultShifts)
  result.ticksPerShift = node{"ticksPerShift"}.getInt(DefaultTicksPerShift)
  result.cycles = node{"cycles"}.getInt(DefaultCycles)
  result.chargeMax = node{"chargeMax"}.getInt(DefaultChargeMax)
  result.charge0 = node{"charge0"}.getInt(DefaultCharge0)
  result.chargeDecayPeriod =
    node{"chargeDecayPeriod"}.getInt(DefaultChargeDecayPeriod)
  result.reactionCooldown =
    node{"reactionCooldown"}.getInt(DefaultReactionCooldown)
  result.coldStartCost = node{"coldStartCost"}.getInt(DefaultColdStartCost)
  result.foodLifetime = node{"foodLifetime"}.getInt(DefaultFoodLifetime)
  result.moveCooldown = node{"moveCooldown"}.getInt(DefaultMoveCooldown)
  result.carryCap = node{"carryCap"}.getInt(DefaultCarryCap)
  result.ventPeriod = node{"ventPeriod"}.getInt(DefaultVentPeriod)
  result.ventGroundCap = node{"ventGroundCap"}.getInt(DefaultVentGroundCap)
  result.distractorPeriod =
    node{"distractorPeriod"}.getInt(DefaultDistractorPeriod)
  result.distractorGroundCap =
    node{"distractorGroundCap"}.getInt(DefaultDistractorGroundCap)
  result.showPlayerLabels = node{"showPlayerLabels"}.getBool(true)
