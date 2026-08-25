## The Chemistry replay: `chemistry.replay.v1`, strict UTF-8 JSON, one
## document.
##
## Rewritten from `coworld-ctf/src/ctf/replays.nim` + `replay_runtime.nim`:
## Chemistry records STATE, not inputs, so playback never re-simulates, a seek
## is an array index, and there is no native/wasm divergence to chase (which
## is also why `#mmwarn` and `ctf_mismatch_tick` are dropped).

import std/json
import sim_types, sim_config, sim_state, events, sim

const ReplayProtocol* = "chemistry.replay.v1"

type
  ReplayData* = object
    protocol*: string
    game*: string
    gameVersion*: string
    seed*: int
    names*: seq[string]
    policyNames*: seq[string]
    colors*: seq[string]
    config*: GameConfig
    configNode*: JsonNode
    frames*: seq[Frame]
    series*: seq[seq[int]]
    beats*: JsonNode
    events*: JsonNode
    results*: JsonNode

  ReplayPlayer* = object
    ## Playback cursor over the recorded frames. Index-based: a seek is an
    ## array index and costs nothing.
    data*: ReplayData
    index*: int
    playing*: bool
    speedIndex*: int
    looping*: bool
    skipLulls*: bool
    endHoldFrames*: int
    accumulator*: int

proc beatsJson*(sim: Sim): JsonNode =
  result = newJArray()
  for beat in sim.beats:
    var row = %*{"t": beat.tick, "k": beat.kind}
    if beat.n > 0:
      row["n"] = %beat.n
    if beat.reactor.len > 0:
      row["rx"] = %beat.reactor
    result.add row

proc seriesJson*(sim: Sim): JsonNode =
  var charge = newJArray()
  for row in sim.chargeSeries:
    var entry = newJArray()
    for value in row:
      entry.add(%value)
    charge.add entry
  %*{"charge": charge}

proc buildReplay*(sim: Sim, results: JsonNode): string =
  ## Self-sufficient by construction: aliases, policy names, body colours, the
  ## whole room geometry, every rule constant, the seed, per-tick state, the
  ## charge series, the beat timeline, every event and the final results all
  ## live in these bytes. The viewer contacts NO server except S3.
  var names = newJArray()
  var policyNames = newJArray()
  var colors = newJArray()
  for slot in 0 ..< Seats:
    names.add(%sim.cogs[slot].alias)
    policyNames.add(%sim.policyNames[slot])
    colors.add(%sim.cogs[slot].color)
  var frames = newJArray()
  for frame in sim.frames:
    frames.add frame.frameJson()
  $ %*{
    "protocol": ReplayProtocol,
    "game": "chemistry",
    "gameVersion": GameVersion,
    "seed": sim.config.seed,
    "names": names,
    "policyNames": policyNames,
    "colors": colors,
    "config": sim.config.configJson(),
    "frames": frames,
    "series": sim.seriesJson(),
    "beats": sim.beatsJson(),
    "events": sim.events.eventsJson(),
    "results": results
  }

proc parseReplayBytes*(data: string): ReplayData =
  let node = parseJson(data)
  result.protocol = node{"protocol"}.getStr()
  if result.protocol != ReplayProtocol:
    raise newException(ChemistryError,
      "unknown replay protocol: " & result.protocol)
  result.game = node{"game"}.getStr("chemistry")
  result.gameVersion = node{"gameVersion"}.getStr(GameVersion)
  result.seed = node{"seed"}.getInt()
  for item in node{"names"}:
    result.names.add item.getStr()
  for item in node{"policyNames"}:
    result.policyNames.add item.getStr()
  for item in node{"colors"}:
    result.colors.add item.getStr()
  result.configNode = node{"config"}
  if result.configNode.isNil or result.configNode.kind != JObject:
    raise newException(ChemistryError, "replay carries no config block")
  result.config = configFromJson(result.configNode)
  for item in node{"frames"}:
    result.frames.add frameFromJson(item)
  if result.frames.len == 0:
    raise newException(ChemistryError, "replay carries no frames")
  let series = node{"series"}
  if not series.isNil and series.kind == JObject:
    for row in series{"charge"}:
      var entry: seq[int]
      for value in row:
        entry.add value.getInt()
      result.series.add entry
  result.beats = node{"beats"}
  if result.beats.isNil: result.beats = newJArray()
  result.events = node{"events"}
  if result.events.isNil: result.events = newJArray()
  result.results = node{"results"}
  if result.results.isNil: result.results = newJObject()
  while result.names.len < Seats:
    result.names.add SeatAliases[result.names.len]
  while result.policyNames.len < Seats:
    result.policyNames.add result.names[result.policyNames.len]
  while result.colors.len < Seats:
    result.colors.add SeatColors[result.colors.len]

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.index = 0
  result.playing = true
  result.speedIndex = 0
  result.looping = true

proc maxTick*(player: ReplayPlayer): int =
  player.data.frames[^1].tick

proc startTick*(player: ReplayPlayer): int =
  player.data.frames[0].tick

proc currentTick*(player: ReplayPlayer): int =
  player.data.frames[player.index].tick

proc replaySpeed*(player: ReplayPlayer): int =
  PlaybackSpeeds[max(0, min(PlaybackSpeeds.high, player.speedIndex))]

proc seekTick*(player: var ReplayPlayer, tick: int) =
  var index = 0
  for i, frame in player.data.frames:
    if frame.tick <= tick:
      index = i
    else:
      break
  player.index = index
  player.endHoldFrames = 0

proc applySpeedCommand(speedIndex: var int, command: char) =
  case command
  of '+', '=': speedIndex = min(PlaybackSpeeds.high, speedIndex + 1)
  of '-', '_': speedIndex = max(0, speedIndex - 1)
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc applyCommand*(player: var ReplayPlayer, command: char) =
  case command
  of ' ': player.playing = not player.playing
  of 'p': player.playing = true
  of 'P': player.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '8', '6':
    applySpeedCommand(player.speedIndex, command)
  of ',', '<':
    player.playing = false
    player.seekTick(player.startTick())
  of 'b':
    player.playing = false
    player.index = max(0, player.index - 1)
    player.endHoldFrames = 0
  of 'e':
    player.playing = false
    player.seekTick(player.maxTick())
  of 'r': player.looping = not player.looping
  of 'f': player.skipLulls = not player.skipLulls
  of '.', '>':
    player.playing = false
    player.seekTick(player.currentTick() + TargetFps * 5)
  else: discard

const EndHoldFrames* = TargetFps * 4
  ## A looping replay holds the final frame for four seconds before it
  ## restarts, so the end card is readable.

proc advance*(player: var ReplayPlayer): tuple[fromTick, toTick: int] =
  ## Advances one presentation frame. Returns the (exclusive, inclusive) tick
  ## span crossed, which is the window the chrome frame's `events` covers.
  let before = player.currentTick()
  if not player.playing:
    return (before, before)
  if player.index >= player.data.frames.high:
    if player.looping:
      if player.endHoldFrames < EndHoldFrames:
        player.endHoldFrames.inc
        return (before, before)
      player.endHoldFrames = 0
      player.index = 0
      return (player.currentTick() - 1, player.currentTick())
    return (before, before)
  player.index = min(player.data.frames.high,
    player.index + player.replaySpeed())
  (before, player.currentTick())

proc endHoldSecondsLeft*(player: ReplayPlayer): int =
  if player.endHoldFrames <= 0: 0
  else: (EndHoldFrames - player.endHoldFrames + TargetFps - 1) div TargetFps

proc eventsBetween*(player: ReplayPlayer, fromTick, toTick: int): JsonNode =
  result = newJArray()
  if toTick <= fromTick:
    return
  for event in player.data.events:
    let tick = event{"t"}.getInt(-1)
    if tick > fromTick and tick <= toTick:
      result.add event

proc leadSeries*(player: ReplayPlayer): JsonNode =
  ## `state.lead` in exactly the shape `client/chrome_common.js`'s
  ## `ingestLeadSeries` expects: {teams: [name...], pts: [[tick, a, b, c]...]}
  ## -- so the cycle-charge strip needs no change to that file.
  var teams = newJArray()
  for reactor in player.data.config.reactorsPresent():
    teams.add(%($reactor))
  var pts = newJArray()
  ## One point per shift boundary plus the endpoints: the whole-timeline
  ## shape, without shipping 720 rows of chrome on the first frame.
  let step = max(1, player.data.config.ticksPerShift div 2)
  for index, row in player.data.series:
    if index == 0 or index == player.data.series.high or
        row[0] mod step == 0:
      var point = newJArray()
      for value in row:
        point.add(%value)
      pts.add point
  %*{"teams": teams, "pts": pts}

proc resultsSummary*(player: ReplayPlayer): string =
  let results = player.data.results
  $results{"food_made"}.getInt() & " food made \u00b7 " &
    $results{"food_rotted"}.getInt() & " rotted \u00b7 " &
    $results{"cold_starts"}.getInt() & " cold start" &
    (if results{"cold_starts"}.getInt() == 1: "" else: "s")
