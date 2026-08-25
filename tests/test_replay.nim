## End-to-end + strict UTF-8: play a full scripted episode headless, write the
## artifacts, then re-read the replay BYTES.

import std/[json, os, strutils, unicode, unittest]
import chemistry/sim
import chemistry/replays
import chemistry/broadcast
import chemistry/global

proc playEpisode(seed: int, cycles = 3, distractorPeriod = 2): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.cycles = cycles
  config.distractorPeriod = distractorPeriod
  config.distractorGroundCap = 24
  result = initSim(config)
  result.logEnabled = false
  ## Seat 3 is fed a `say` and `notes` of MULTI-BYTE runes exactly at the
  ## 80/320 caps every shift: a byte cut anywhere in the chain lands invalid
  ## UTF-8 in the replay and only a strict parser finds it (bullwhip,
  ## 2026-08-22).
  let bigSay = "\u00e9\u2014\u00f8".repeat(60)
  let bigNotes = "\u00e9\u2014\u00f8".repeat(200)
  while not result.done:
    for slot in 0 ..< Seats:
      var order = result.courierOrder(slot)
      if slot == 3:
        order.say = sayText(bigSay)
        order.notes = notesText(bigNotes)
        order.source = osLlm
      result.applyOrder(slot, order)
    result.runShift()

suite "replay: end to end and strictly UTF-8":
  let sim = playEpisode(11)
  let results = sim.resultsJson()
  let bytes = buildReplay(sim, results)
  let path = getTempDir() / "chemistry-test-replay.json"
  writeFile(path, bytes)
  let raw = readFile(path)

  test "the bytes are strictly valid UTF-8":
    check validateUtf8(raw) == -1

  test "the document parses and is self-sufficient":
    let node = parseJson(raw)
    check node{"protocol"}.getStr() == "chemistry.replay.v1"
    check node{"game"}.getStr() == "chemistry"
    check node{"gameVersion"}.getStr() == GameVersion
    check node{"seed"}.getInt() == 11
    check node{"names"}.len == 8
    check node{"policyNames"}.len == 8
    check node{"colors"}.len == 8
    check node{"config"}.kind == JObject
    check node{"config"}{"cols"}.getInt() == RoomCols
    check node{"config"}{"rows"}.getInt() == RoomRows
    check node{"results"}.kind == JObject

  test "frames and the charge series cover the opening state and every tick played":
    let node = parseJson(raw)
    ## One frame for the opening state (tick 0) plus one per tick played.
    check node{"frames"}.len == sim.tick + 1
    check node{"series"}{"charge"}.len == sim.tick + 1
    check node{"frames"}[0]{"t"}.getInt() == 0
    check node{"series"}{"charge"}[0][0].getInt() == 0
    check node{"frames"}[node{"frames"}.len - 1]{"t"}.getInt() == sim.tick
    for index, frame in node{"frames"}.getElems():
      check frame{"t"}.getInt() == index
      check frame{"t"}.getInt() <= sim.tick

  test "every event tick is inside the played range and the vocabulary is complete":
    let node = parseJson(raw)
    var counts: array[EventKind, int]
    for event in node{"events"}:
      let tick = event{"t"}.getInt(-1)
      check tick >= 0
      check tick <= sim.tick
      for kind in EventKind:
        if $kind == event{"k"}.getStr():
          counts[kind].inc
    check counts[evTake] > 0
    check counts[evDrop] > 0
    check counts[evReact] > 0
    check counts[evEat] > 0
    check counts[evShift] == sim.shift
    check counts[evEnd] == 1

  test "beats carry only the five declared kinds":
    let node = parseJson(raw)
    for beat in node{"beats"}:
      check beat{"k"}.getStr() in
        ["shift", "cold", "restart", "famine", "gameover"]

  test "results are the shape the platform reads":
    let node = parseJson(raw){"results"}
    check node{"scores"}.len == 8
    check node{"names"}.len == 8
    check node{"win"}.len == 8
    check node{"reason"}.getStr() in ["complete", "deadline", "forfeit"]
    check node{"ending"}.getStr() in
      ["shift_limit", "famine", "deadline", "forfeit"]
    for index in 0 ..< node{"scores"}.len:
      check node{"scores"}[index].getInt() ==
        node{"food_eaten"}[index].getInt()

  test "the recorded caps hold on RUNE boundaries":
    let node = parseJson(raw)
    var sawLong = false
    for event in node{"events"}:
      if event{"k"}.getStr() != "order":
        continue
      let say = event{"say"}.getStr()
      let notes = event{"notes"}.getStr()
      check validateUtf8(say) == -1
      check validateUtf8(notes) == -1
      check say.runeLen <= MaxSayLen
      check notes.runeLen <= MaxNotesLen
      if say.runeLen == MaxSayLen and notes.runeLen == MaxNotesLen:
        sawLong = true
    check sawLong

  test "the file is well under the 8 MiB ceiling":
    check raw.len < 8 * 1024 * 1024

  test "the replay round-trips through the viewer's parser":
    let data = parseReplayBytes(raw)
    check data.frames.len == sim.tick + 1
    check data.config.shifts == sim.config.shifts
    var player = initReplayPlayer(data)
    check player.maxTick() == sim.tick
    player.seekTick(sim.tick div 2)
    check player.currentTick() <= sim.tick div 2 + 1
    let span = player.advance()
    check span.toTick >= span.fromTick
    check player.leadSeries(){"teams"}.len == sim.reactors.len

  removeFile(path)

suite "the viewer plays the recorded frames without re-simulating":
  ## The static bundle's Nim half: parse -> hydrate -> build one board packet
  ## and one chrome frame per presentation frame. Everything here is exactly
  ## what `replay-viewer/chemistry_replay.nim` calls; only the emscripten
  ## exports and the JS bootstrap live outside it.
  let sim = playEpisode(3)
  let data = parseReplayBytes(buildReplay(sim, sim.resultsJson()))

  test "every frame builds a non-empty packet carrying the chrome":
    var player = initReplayPlayer(data)
    var viewer = initGlobalViewerState()
    var tracker = initBroadcastTracker(data.config.reactorsPresent().len)
    let room = buildRoom(data.config)
    var frames = 0
    var chromeFrames = 0
    while frames < 60:
      let span = player.advance()
      let board = BoardInput(config: data.config, room: room,
        names: data.names, colors: data.colors,
        frame: data.frames[player.index])
      var next: GlobalViewerState
      var packet = buildBoardPacket(board, viewer, next)
      viewer = next
      check packet.len > 0
      var input = ChromeInput(
        config: data.config, names: data.names,
        policyNames: data.policyNames, colors: data.colors,
        frame: data.frames[player.index], tick: player.currentTick(),
        maxTick: player.maxTick(), startTick: player.startTick(),
        shift: player.currentTick() div data.config.ticksPerShift,
        phase: "playing", playing: true, transportEnabled: true, speed: 1,
        events: player.eventsBetween(span.fromTick, span.toTick))
      tracker.rebuild(data.config, data.events, input.tick)
      input.tracker = tracker
      let chrome = buildStateJson(input)
      check parseJson(chrome){"t"}.getInt() == player.currentTick()
      packet.addChromeFrame(chrome)
      inc chromeFrames
      inc frames
    check chromeFrames == 60

  test "every recorded event lands in some frame's event window":
    ## The feed is driven by `eventsBetween(previousFrameTick, thisFrameTick)`.
    ## The eight shift-1 `order` rows are stamped at tick 0, so the load
    ## packet's window opens at `startTick - 1` -- exactly what
    ## `replay-viewer/chemistry_replay.nim` passes. Nothing recorded may fall
    ## outside the union of the windows.
    var player = initReplayPlayer(data)
    var delivered = 0
    var previous = player.startTick() - 1
    for index in 0 .. data.frames.high:
      let tick = data.frames[index].tick
      delivered += player.eventsBetween(previous, tick).len
      previous = tick
    check delivered == data.events.len
    var shiftOneOrders = 0
    for event in player.eventsBetween(player.startTick() - 1,
        player.startTick()):
      if event{"k"}.getStr() == "order":
        inc shiftOneOrders
    check shiftOneOrders == Seats

  test "a seek is an array index, and the transport commands land":
    var player = initReplayPlayer(data)
    player.applyCommand(' ')
    check not player.playing
    player.applyCommand('e')
    check player.currentTick() == player.maxTick()
    player.applyCommand(',')
    check player.currentTick() == player.startTick()
    player.applyCommand('8')
    check player.replaySpeed() == 8
    player.seekTick(300)
    check player.currentTick() == 300
