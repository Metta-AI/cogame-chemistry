## Chemistry game server: implements the Coworld game contract.
##
## Fork of `coworld-ctf/src/ctf/server.nim`'s route / artifact / shutdown
## skeleton with bullwhip's JSON player protocol. Hosted certification probes
## exactly these routes BEFORE the player pods start (lantern, 2026-08-23), so
## none of them may 404 and none of them may open a player socket:
##
##   GET /healthz                    200 from process start until
##                                   shutdownGraceSeconds after the artifacts
##   GET /client/player?slot&token   the seat's HTML shell (view only)
##   GET /client/global              the broadcast client
##   WS  /player?slot=N&token=T      the seat socket; a bad token is REFUSED
##   WS  /global                     live spectator: sprite protocol + chrome
##
## `chemistry.player.v2` frames, JSON text:
##   game -> player: welcome, state, observation (external seats), final
##   player -> game: prompt, register external, action with decision id/order id

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  bitworld/spriteprotocol,
  broadcast, global, llm, replays, sim, wire_constants

const
  PlayBudgetFraction = 0.6
    ## Share of the platform's episode timeout spent playing. The rest covers
    ## container start, player connects and writing the artifacts -- the part
    ## that must never be the thing that runs out of time.
  BroadcastPage = staticRead("../../client/replay_broadcast.html")
  ChromeCommonJs = staticRead("../../client/chrome_common.js")
  BroadcastCoreJs = staticRead("../../client/broadcast_core.js")
  PlayerPage = staticRead("../../client/player.html")
  ChromeMarker = "<!-- CHROME_COMMON -->"
  CoreMarker = "<!-- BROADCAST_CORE -->"

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    external: seq[bool]
    registered: seq[bool]
    decisionId: int
    pending: seq[bool]
    accepted: seq[bool]
    actions: seq[Order]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewers: Table[WebSocket, GlobalViewerState]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server

initLock(stateLock)

proc splicedBroadcastPage(): string =
  spliceWireConstants(BroadcastPage)
    .replace(ChromeMarker, "<script>" & ChromeCommonJs & "</script>")
    .replace(CoreMarker, "<script>" & BroadcastCoreJs & "</script>")

# --------------------------------------------------------------------------
# Broadcast
# --------------------------------------------------------------------------

proc chromeInputLocked(gs: GameState, events: JsonNode): ChromeInput =
  result.config = gs.config
  for slot in 0 ..< Seats:
    result.names.add gs.sim.cogs[slot].alias
    result.policyNames.add gs.sim.policyNames[slot]
    result.colors.add gs.sim.cogs[slot].color
  result.frame =
    if gs.sim.frames.len > 0: gs.sim.frames[^1] else: gs.sim.buildFrame()
  result.tick = gs.sim.tick
  result.maxTick = gs.sim.ticksTotal()
  result.startTick = 0
  result.shift = gs.sim.shift
  result.phase = ($gs.sim.phase).toLowerAscii()
  result.playing = not gs.sim.done
  result.speed = 1.0
  result.transportEnabled = false
  result.events = events
  result.beats = gs.sim.beatsJson()
  ## The cycle-charge strip reads `lead`; a live spectator gets the same
  ## whole-timeline shape the replay bundle ships, as far as the room has
  ## played.
  result.lead = chargeLeadSeries(gs.config, gs.sim.chargeSeries)
  var tracker = initBroadcastTracker(gs.sim.reactors.len)
  tracker.rebuild(gs.config, gs.sim.events.eventsJson(), gs.sim.tick)
  result.tracker = tracker
  if gs.sim.done:
    result.results = gs.sim.resultsJson()

proc broadcastBoardLocked(gs: var GameState, events: JsonNode) =
  if gs.globalSockets.len == 0:
    return
  var names, colors: seq[string]
  for slot in 0 ..< Seats:
    names.add gs.sim.cogs[slot].alias
    colors.add gs.sim.cogs[slot].color
  let board = BoardInput(
    config: gs.config, room: gs.sim.room, names: names, colors: colors,
    frame: (if gs.sim.frames.len > 0: gs.sim.frames[^1] else: gs.sim.buildFrame()))
  let chrome = buildStateJson(gs.chromeInputLocked(events))
  for socket in gs.globalSockets:
    var viewer = gs.viewers.getOrDefault(socket, initGlobalViewerState())
    var next: GlobalViewerState
    var packet = buildBoardPacket(board, viewer, next)
    packet.addChromeFrame(chrome)
    gs.viewers[socket] = next
    socket.send(packet.blobFromBytes(), BinaryMessage)

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  gs.sim.observationJson(slot)

# --------------------------------------------------------------------------
# Artifacts
# --------------------------------------------------------------------------

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  var grace = 20
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    grace = state.config.shutdownGraceSeconds
    results = state.sim.resultsJson()
    replayData = buildReplay(state.sim, results)

    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists, and writing
    ## first would race player log collection. Results carry POLICY names for
    ## the platform; the player sockets get the table ALIASES.
    var aliases = newJArray()
    for slot in 0 ..< Seats:
      aliases.add(%state.sim.cogs[slot].alias)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "names": aliases,
      "shifts": results["shifts"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastBoardLocked(newJArray())

  sleep(500)
  echo "chemistry: writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  ## Hosted certification pings the global websocket AFTER the player pods
  ## start, and a short episode can already be gone by then (lantern
  ## 0.1.3 -> 0.1.4). Keep /healthz and /global answering for a bounded grace
  ## before exiting; the runner waits on process exit anyway.
  echo "chemistry: artifacts written; serving for ", grace,
    "s of shutdown grace"
  sleep(grace * 1000)
  echo "chemistry: episode complete, shutting down"
  quit(0)

# --------------------------------------------------------------------------
# The shift loop
# --------------------------------------------------------------------------

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline =
      gameStart + config.playerConnectTimeoutSeconds.float

    while epochTime() < connectDeadline:
      var connected = 0
      withLock stateLock:
        for slot in 0 ..< config.numAgents:
          if state.playerSockets.hasKey(slot) and state.registered[slot]:
            inc connected
      if connected >= config.numAgents:
        break
      sleep(200)

    var anyConnected = false
    withLock stateLock:
      state.started = true
      anyConnected = state.playerSockets.len > 0
      echo "chemistry: starting with ", state.playerSockets.len, "/",
        config.numAgents, " players connected"

    if not anyConnected:
      ## No seat connected within playerConnectTimeoutSeconds: forfeit, all
      ## zero, results and the replay are still written.
      withLock stateLock:
        echo "chemistry: no player connected; forfeiting"
        state.sim.stepTick()
        state.sim.forfeit()
      finishEpisode(runtimeConfig)
      return

    let client = newLlmClient(config)

    ## The hosted dispatcher hands COWORLD_TIMEOUT_SECONDS only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline = gameStart + timeoutSeconds * PlayBudgetFraction
    echo "chemistry: episode timeout ", timeoutSeconds.int, "s (",
      (if hostedTimeout.len > 0: "from env" else: "assumed"),
      "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      withLock stateLock:
        if state.sim.done:
          break
        if epochTime() > playDeadline:
          ## The platform kills an episode that outruns its timeout and keeps
          ## nothing at all, so give up shifts rather than the whole result:
          ## stop here, BETWEEN shifts.
          echo "chemistry: play deadline reached after ", state.sim.shift, "/",
            config.shifts, " shifts; ending early"
          state.sim.endEarly()
          state.broadcastBoardLocked(newJArray())
          break
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        echo "chemistry: shift ", state.sim.shift + 1, " of ", config.shifts,
          " at ", (epochTime() - gameStart).int, "s"

      ## Send every external seat the same simultaneous shift snapshot before
      ## waiting for any reply. The game still owns observation and legality.
      var clientScripted = newSeq[ScriptKind](Seats)
      for slot in 0 ..< Seats:
        clientScripted[slot] = scripted[slot]
      withLock stateLock:
        inc state.decisionId
        for slot in 0 ..< Seats:
          if state.external[slot]:
            clientScripted[slot] = skCourier
            state.pending[slot] = true
            state.accepted[slot] = false
            if state.playerSockets.hasKey(slot):
              state.playerSockets[slot].send($ %*{
                "type": "observation", "id": state.decisionId,
                "observation": simCopy.observationJson(slot)
              })
          elif not state.registered[slot]:
            clientScripted[slot] = skCourier

      ## Prompt seats remain one parallel model batch; external seats keep a
      ## courier order until their own legal reply arrives.
      let batchStart = epochTime()
      var orders = client.decideAll(simCopy, prompts, clientScripted)
      let deadline = epochTime() + config.llmTimeoutSeconds.float
      while epochTime() < deadline:
        var waiting = false
        withLock stateLock:
          for slot in 0 ..< Seats:
            if state.pending[slot] and not state.accepted[slot] and
                state.playerSockets.hasKey(slot):
              waiting = true
        if not waiting:
          break
        sleep(20)

      withLock stateLock:
        for slot in 0 ..< Seats:
          if state.pending[slot]:
            if state.accepted[slot]:
              orders[slot] = state.actions[slot]
            else:
              orders[slot].source = osFallback
          state.pending[slot] = false

      withLock stateLock:
        ## The `order` events fire from applyOrder, BEFORE the shift's first
        ## tick, so the broadcast window has to open before them or the live
        ## feed never shows a standing order at all.
        let before = state.sim.events.len
        for slot in 0 ..< Seats:
          state.sim.applyOrder(slot, orders[slot])
        state.sim.runShift()
        var events = newJArray()
        for index in before ..< state.sim.events.len:
          events.add state.sim.events[index].jsonRow()
        state.broadcastBoardLocked(events)
        for slot, socket in state.playerSockets:
          socket.send($state.playerStateJson(slot))

      ## Floor the spacing between batch STARTS so the episode stays under the
      ## Bedrock sidecar's 30 requests/minute per-episode ceiling that bit
      ## cogame-raid.
      let elapsed = epochTime() - batchStart
      if config.minTurnSeconds > 0 and elapsed < config.minTurnSeconds.float:
        sleep(int((config.minTurnSeconds.float - elapsed) * 1000))

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, splicedBroadcastPage())

proc playerPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, PlayerPage)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var alias = ""
    var variant = ""
    var shifts = 0
    var ticksPerShift = 0
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
      if authorized:
        alias = state.sim.cogs[slot].alias
        variant = state.config.variantId()
        shifts = state.config.shifts
        ticksPerShift = state.config.ticksPerShift
    if not authorized:
      ## Refused with a status, never a hang.
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      ## The decision layer only calls the LLM for a seat with a live socket;
      ## every other seat plays `courier` (design: "a seat that never
      ## connected, or whose socket dies mid-episode, plays courier for every
      ## remaining shift").
      state.sim.cogs[slot].connected = true
      echo "chemistry: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.numAgents, ")"
    websocket.send($ %*{
      "type": "welcome",
      "protocol": "chemistry.player.v2",
      "slot": slot,
      "name": alias,
      "shifts": shifts,
      "ticksPerShift": ticksPerShift,
      "variant": variant
    })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      state.viewers[websocket] = initGlobalViewerState()
      state.broadcastBoardLocked(newJArray())

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        withLock stateLock:
          if websocket in state.viewers:
            var viewer = state.viewers[websocket]
            viewer.applyGlobalViewerMessage(message.data)
            state.viewers[websocket] = viewer
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let scripted =
            if node.isNil: skNone
            elif node.kind == JBool:
              (if node.getBool(): skCourier else: skNone)
            else: parseScriptKind(node.getStr())
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.external[slot] = false
            state.registered[slot] = true
          echo "chemistry: slot ", slot, " delivered a prompt (", prompt.len,
            " chars", (if scripted != skNone: ", scripted " & $scripted
                       else: ""), ")"
        elif payload{"type"}.getStr() == "register" and
            payload["control"].getStr() == "external":
          withLock stateLock:
            state.external[slot] = true
            state.registered[slot] = true
          echo "chemistry: slot ", slot, " registered external control"
        elif payload{"type"}.getStr() == "action":
          let id = payload["id"].getInt()
          let orderId = payload["orderId"].getStr()
          withLock stateLock:
            if state.external[slot] and state.pending[slot] and
                state.decisionId == id and not state.accepted[slot]:
              for option in state.sim.legalOrders():
                if option["id"].getStr() == orderId:
                  var reply = parseJson($option)
                  reply["say"] = %payload{"say"}.getStr()
                  reply["notes"] = %payload{"notes"}.getStr()
                  state.actions[slot] = state.sim.parseDecision(reply)
                  state.actions[slot].source = osExternal
                  state.accepted[slot] = true
                  break
        else:
          echo "chemistry: ignoring player frame of type ",
            payload{"type"}.getStr()
      except CatchableError as error:
        echo "chemistry: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
            ## The socket died mid-episode: this seat plays `courier` from
            ## here on rather than being prompted with nobody listening.
            state.sim.cogs[slot].connected = false
            echo "chemistry: player slot ", slot,
              " disconnected; playing courier for the rest of the episode"
        state.globalSockets.excl(websocket)
        state.viewers.del(websocket)

proc buildRouter(): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len < config.numAgents:
    raise newException(ChemistryError,
      "config must carry one token per seat (" & $config.numAgents & ")")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](Seats)
  state.scripted = newSeq[ScriptKind](Seats)
  state.external = newSeq[bool](Seats)
  state.registered = newSeq[bool](Seats)
  state.pending = newSeq[bool](Seats)
  state.accepted = newSeq[bool](Seats)
  state.actions = newSeq[Order](Seats)
  let router = buildRouter()
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "chemistry: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
