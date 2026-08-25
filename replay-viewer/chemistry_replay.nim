import
  std/json,
  chemistry/[broadcast, global, replays, sim]

var
  runtimeLoaded = false
  player: ReplayPlayer
  tracker: BroadcastTracker
  viewer: GlobalViewerState
  packet: seq[uint8]
  lastError: string
  leadSent = false

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 -- allocation failure aborts the runtime loudly --
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not the linear memory).
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc buildChrome(events: JsonNode, sendLead: bool): string =
  var input = ChromeInput(
    config: player.data.config,
    names: player.data.names,
    policyNames: player.data.policyNames,
    colors: player.data.colors,
    frame: player.data.frames[player.index],
    tick: player.currentTick(),
    maxTick: player.maxTick(),
    startTick: player.startTick(),
    playing: player.playing,
    looping: player.looping,
    skipLulls: player.skipLulls,
    fastForwarding: false,
    transportEnabled: true,
    speed: player.replaySpeed(),
    events: events,
    holdSeconds: player.endHoldSecondsLeft()
  )
  input.shift = player.currentTick() div max(1, input.config.ticksPerShift)
  input.phase =
    if player.currentTick() >= player.maxTick(): "gameover" else: "playing"
  tracker.rebuild(input.config, player.data.events, input.tick)
  input.tracker = tracker
  input.results = player.data.results
  ## The load packet is the ONLY one that carries the whole-timeline chrome
  ## (the beat list and the charge series). Every later frame omits it and the
  ## client keeps its cached copy -- never re-derive it by seeking back to the
  ## first frame (matrix-games, 2026-08-24).
  if sendLead:
    input.beats = player.data.beats
    input.lead = player.leadSeries()
  buildStateJson(input)

proc renderCurrent(events: JsonNode, sendLead: bool) =
  var names, colors: seq[string]
  names = player.data.names
  colors = player.data.colors
  let board = BoardInput(
    config: player.data.config,
    room: buildRoom(player.data.config),
    names: names,
    colors: colors,
    frame: player.data.frames[player.index])
  var next: GlobalViewerState
  packet = buildBoardPacket(board, viewer, next)
  viewer = next
  packet.addChromeFrame(buildChrome(events, sendLead))

proc chemistryLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "chemistry_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay playback")
    player = initReplayPlayer(replayData)
    tracker = initBroadcastTracker(replayData.config.reactorsPresent().len)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    frameStage = "advance replay (" & $replayData.frames.len & " frames)"
    stampStage("render first frame")
    renderCurrent(newJArray(), true)
    leadSent = true
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc chemistryInput(data: ptr uint8, length: cint)
    {.exportc: "chemistry_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc chemistryFrame(): cint {.exportc: "chemistry_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    var jumped = false
    if viewer.replaySeekTick >= 0:
      player.seekTick(viewer.replaySeekTick)
      viewer.replaySeekTick = -1
      jumped = true
    for command in viewer.replayCommands:
      let before = player.currentTick()
      player.applyCommand(command)
      if player.currentTick() != before:
        jumped = true
    viewer.replayCommands.setLen(0)
    let span = player.advance()
    let events =
      if jumped: newJArray() else: player.eventsBetween(span.fromTick, span.toTick)
    renderCurrent(events, false)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc chemistryPacketPointer(): ptr uint8
    {.exportc: "chemistry_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc chemistryPacketLength(): cint {.exportc: "chemistry_packet_len", cdecl.} =
  cint(packet.len)

proc chemistryErrorPointer(): ptr uint8
    {.exportc: "chemistry_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc chemistryErrorLength(): cint {.exportc: "chemistry_error_len", cdecl.} =
  cint(lastError.len)

proc chemistryStagePointer(): ptr uint8
    {.exportc: "chemistry_stage_ptr", cdecl.} =
  ## The progress note. Unlike chemistry_error_*, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing
  ## when the address space ran out.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc chemistryStageLength(): cint {.exportc: "chemistry_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the parsed replay, the baked board art and the fonts -- everything
  # -- while the wasm module stays alive and JS keeps calling
  # chemistry_load_replay / chemistry_frame. Unwinding main through
  # emscripten's live-runtime exit skips the destructor epilogue entirely, so
  # globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
