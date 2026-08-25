## Claude-backed decision making for Chemistry.
##
## Forked from `cogame-bullwhip/src/bullwhip/llm.nim` (the game-side batched
## decision layer paintbot does not have). A policy is just a prompt: the game
## composes each seat's observation plus that seat's `PLAYER_PROMPT` and asks
## Claude for ONE standing order for the next shift.
##
## Decisions within a shift are simultaneous by rule, so all eight seats'
## requests go out as ONE parallel batch (`curly.makeRequests`); invalid
## replies are retried once as a smaller batch carrying a hint, and anything
## still failing falls back to the `courier` order.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With none the client disables itself immediately and every seat plays
## `courier` -- which is what keeps offline certification green and
## deterministic. That fallback is load-bearing, not a convenience.

import
  std/[json, os, strutils, times],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool
    lastBatchSize*: int   ## seats carried by the most recent request batch

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "chemistry llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds*(): seq[string] =
  ## Haiku ONLY. The sonnet inference profiles time out on every sidecar call
  ## and turn one throttle into a cascade of scripted fallbacks (raid,
  ## 2026-08-23), so this ladder has exactly one rung. BEDROCK_MODEL pins a
  ## different id when an operator needs one.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "chemistry llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "chemistry llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel], ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "chemistry llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "chemistry llm: no LLM credentials; every seat plays courier"

# ---- The observation ---------------------------------------------------------

proc reactorJson(sim: Sim, index: int): JsonNode =
  let reactor = sim.reactors[index]
  var feeds = newJArray()
  for species in reactor.feed:
    feeds.add(%($species))
  %*{
    "name": $reactor.name,
    "cell": [reactor.cell.x, reactor.cell.y],
    "feedstocks": feeds,
    "charge": reactor.charge,
    "chargeMax": sim.config.chargeMax,
    "status": $sim.reactorStatus(index),
    "yieldNow": sim.yieldNow(index),
    "stock": {$reactor.feed[0]: reactor.stock[0],
              $reactor.feed[1]: reactor.stock[1]},
    "cooldown": reactor.cooldown,
    "ticksSinceReaction": reactor.ticksSinceReaction,
    "foodMade": reactor.foodMade,
    "coldStartCost": sim.config.coldStartCost
  }

proc nearestCellOf(sim: Sim, slot: int, species: Species): JsonNode =
  let cells = sim.looseCells(species)
  if cells.len == 0:
    return newJNull()
  let field = sim.room.distanceField(cells)
  var best = Cell(x: -1, y: -1)
  var bestDistance = high(int)
  for cell in cells:
    let distance = manhattan(cell, sim.cogs[slot].cell)
    if distance < bestDistance:
      bestDistance = distance
      best = cell
  discard field
  %*[best.x, best.y]

proc orderJson(order: Order, withSource: bool): JsonNode =
  result = %*{"job": $order.job}
  if order.hasMolecule:
    result["molecule"] = %($order.molecule)
  if order.hasReactor:
    result["reactor"] = %($order.reactor)
  if withSource:
    result["source"] = %($order.source)

proc observationJson*(sim: Sim, slot: int): JsonNode =
  ## The `state` frame each seat gets at every shift boundary. Everything in
  ## here is visible to that seat; NOTHING else is -- in particular no policy
  ## name, no other seat's notes and no other seat's order for the shift about
  ## to be played (decisions are simultaneous).
  let cog = sim.cogs[slot]
  var reactors = newJArray()
  for index in 0 ..< sim.reactors.len:
    reactors.add sim.reactorJson(index)
  var molecules = newJObject()
  for species in sim.config.speciesPresent():
    molecules[$species] = %*{
      "inert": species.isInert(),
      "vent": [VentCells[species].x, VentCells[species].y],
      "loose": sim.looseCount(species),
      "nearestToYou": sim.nearestCellOf(slot, species)
    }
  var foodCellsJson = newJArray()
  for cell in sim.foodCells():
    foodCellsJson.add(%*[cell.x, cell.y])
  var cogs = newJArray()
  for other in 0 ..< Seats:
    let entry = sim.cogs[other]
    cogs.add(%*{
      "alias": entry.alias,
      "cell": [entry.cell.x, entry.cell.y],
      "carrying": (if entry.hasCarry: %($entry.carrying) else: newJNull()),
      "foodEaten": entry.foodEaten,
      "delivered": entry.delivered,
      "misdrops": entry.misdrops,
      "hoard": entry.hoard,
      "lastOrder": orderJson(entry.order, false),
      "say": entry.say
    })
  var history = newJArray()
  for record in sim.history:
    var eaten = newJArray()
    for slotEaten in record.eaten:
      eaten.add(%slotEaten)
    var reactions = newJArray()
    for value in record.reactions:
      reactions.add(%value)
    var foodMade = newJArray()
    for value in record.foodMade:
      foodMade.add(%value)
    var charges = newJArray()
    for value in record.charge:
      charges.add(%value)
    history.add(%*{
      "shift": record.shift,
      "reactions": reactions,
      "foodMade": foodMade,
      "eaten": eaten,
      "coldStarts": record.coldStarts,
      "misdrops": record.misdrops,
      "charge": charges
    })
  var rules = newJArray()
  for index in 0 ..< sim.reactors.len:
    let reactor = sim.reactors[index]
    rules.add(%*{
      "reactor": $reactor.name,
      "inputs": [$reactor.feed[0], $reactor.feed[1]],
      "output": "food",
      "yield": "1 + charge div 3",
      "requires": "charge >= 1 and both stocks >= 1"
    })
  var inert = newJArray()
  for species in sim.config.speciesPresent():
    if species.isInert():
      inert.add(%($species))
  %*{
    "type": "state",
    "protocol": "chemistry.player.v1",
    "slot": slot,
    "name": cog.alias,
    "shift": sim.shift + 1,
    "shifts": sim.config.shifts,
    "ticksPerShift": sim.config.ticksPerShift,
    "tick": sim.tick,
    "room": {"cols": RoomCols, "rows": RoomRows,
             "variant": sim.config.variantId()},
    "you": {
      "cell": [cog.cell.x, cog.cell.y],
      "carrying": (if cog.hasCarry: %($cog.carrying) else: newJNull()),
      "home": [cog.home.x, cog.home.y],
      "foodEaten": cog.foodEaten,
      "delivered": cog.delivered,
      "misdrops": cog.misdrops,
      "hoard": cog.hoard,
      "lastOrder": orderJson(cog.order, true)
    },
    "reactors": reactors,
    "molecules": molecules,
    "food": {"loose": sim.foodCells().len, "cells": foodCellsJson},
    "cogs": cogs,
    "history": history,
    "notes": cog.notes,
    "rules": {
      "reactions": rules,
      "autocatalysis": "every reaction adds 1 charge (max " &
        $sim.config.chargeMax & "); yield rises with charge",
      "chargeDecay": "-1 charge per reactor every " &
        $sim.config.chargeDecayPeriod & " ticks (once per shift)",
      "coldStart": "at charge 0 a reactor consumes " &
        $sim.config.coldStartCost & " of EACH feedstock to return to " &
        "charge 1 and makes no food",
      "misdrop": "a molecule dropped on a reactor that does not take it " &
        "is absorbed and destroyed",
      "inert": inert,
      "carryCap": sim.config.carryCap,
      "moveCooldown": sim.config.moveCooldown,
      "foodLifetime": sim.config.foodLifetime,
      "ventPeriod": sim.config.ventPeriod,
      "scoring": "your score is the number of food tokens YOU eat; food is " &
        "eaten automatically by standing on it"
    }
  }

# ---- Prompts ----------------------------------------------------------------

proc titleCase(text: string): string =
  if text.len == 0: text else: text[0..0].toUpperAscii() & text[1 .. ^1]

proc legalJobs(): string = "supply | forage | hoard | idle"

proc legalMolecules(sim: Sim): string =
  var parts: seq[string]
  for species in sim.config.speciesPresent():
    parts.add $species
  parts.join(" | ")

proc legalReactors(sim: Sim): string =
  var parts: seq[string]
  for reactor in sim.reactors:
    parts.add $reactor.name
  parts.join(" | ")

proc graphTable(sim: Sim): string =
  var lines = @["reactor | takes | inert species never accepted"]
  for reactor in sim.reactors:
    lines.add($reactor.name & " | " & $reactor.feed[0] & " + " &
      $reactor.feed[1] & " | glitter, quartz")
  lines.join("\n")

proc systemPrompt*(sim: Sim, slot: int): string =
  let cog = sim.cogs[slot]
  result.add("You are " & cog.alias.toUpperAscii() &
    ", one of eight cogs working a chemistry floor.\n")
  result.add("""
THE ROOM: a fixed 32x18 grid. Walls ring the edge and two 2x2 pillars sit in
the middle. Three vats (reactors) sit on 3x3 pads. Vents emit loose molecules
onto the floor. Cells are (col, row) with the origin at the top left.

WHAT YOU CONTROL: you do NOT emit per-tick moves. Once per SHIFT (60 ticks)
you choose ONE standing order, and a deterministic courier kernel walks it for
you: it paths, picks up, carries and drops. Your per-tick action vocabulary --
move_n, move_s, move_e, move_w, take, drop, wait -- is what the kernel emits
on your behalf. You carry AT MOST ONE molecule (carryCap 1) and may move once
every """ & $sim.config.moveCooldown & """ ticks.

THE JOBS:
- supply: fetch the named molecule and drop it into the named vat's stock.
- forage: walk to loose food, or camp the named vat's spill ring and wait.
- hoard: fetch the named molecule and stack it on your own home cell. Hoarding
  scores NOTHING, ever.
- idle: stand still.

THE REACTION GRAPH:
""" & sim.graphTable() & "\n")
  result.add("""
- A vat reacts when its charge is at least 1, its cooldown is 0 and BOTH its
  feedstocks are in stock: it consumes 1 of each, gains 1 charge (max """ &
    $sim.config.chargeMax & """) and drops 1 + charge div 3 FOOD tokens.
- AUTOCATALYSIS: charge is the catalyst. Every reaction makes the next one
  more productive, but charge decays by 1 every """ &
    $sim.config.chargeDecayPeriod & """ ticks -- once per shift -- so
  "running" is a state you HOLD, not one you reach.
- COLD START: a vat at charge 0 cannot react. It returns to charge 1 only by
  consuming """ & $sim.config.coldStartCost & """ of EACH feedstock, and makes
  no food doing it. Letting a cycle die costs the room six deliveries of pure
  investment.
- MISDROP: a molecule dropped on a vat that does not take it -- an inert
  species, or the third feedstock -- is ABSORBED AND DESTROYED. Reading the
  graph is what stops you paying that.
- INERT species do nothing at all. They can be carried and hoarded, and they
  are a trap.

SCORING: your score is the number of FOOD tokens YOU eat. Food is eaten
automatically by standing on it -- eating is not an action. New tokens appear
on the spill ring nearest the cog that delivered the molecule which triggered
the reaction, so working pays at your own feet. A token rots after """ &
    $sim.config.foodLifetime & """ ticks. Nothing else scores: deliveries,
hoards and misdrops are reported but never ranked.

THE OTHER SEVEN COGS are other policies deciding SIMULTANEOUSLY with you. You
never learn their names, their prompts or the order they are about to give.
Your `say` (max """ & $MaxSayLen & """ characters) is broadcast to all of them
and reaches them in NEXT shift's observation. Your `notes` (max """ &
    $MaxNotesLen & """ characters) are private and come back only to you.

""")
  result.add("Reply with one JSON object: {\"job\": <" & legalJobs() &
    ">, \"molecule\": <" & sim.legalMolecules() & ">, \"reactor\": <" &
    sim.legalReactors() & ">, \"say\": \"...\", \"notes\": \"...\"}.\n")
  result.add("`molecule` is required for supply and hoard; `reactor` is " &
    "required for supply.\n\n")
  result.add("""OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no explanation, no markdown fences, no text before or after the object. Your reply must begin with the character { and end with }.""")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, slot: int, prompt: string): string =
  let cog = sim.cogs[slot]
  result.add("SHIFT " & $(sim.shift + 1) & " of " & $sim.config.shifts &
    " (tick " & $sim.tick & " of " & $sim.ticksTotal() & "). You are " &
    cog.alias.toUpperAscii() & " at (" & $cog.cell.x & "," & $cog.cell.y &
    "), carrying " & (if cog.hasCarry: $cog.carrying else: "nothing") &
    ". You have eaten " & $cog.foodEaten & ", delivered " & $cog.delivered &
    ", misdropped " & $cog.misdrops & ", hoarded " & $cog.hoard & ".\n\n")

  result.add("VATS:\nreactor | takes | charge | status | stock | yield next " &
    "| food made\n")
  for index in 0 ..< sim.reactors.len:
    let reactor = sim.reactors[index]
    result.add($reactor.name & " | " & $reactor.feed[0] & "+" &
      $reactor.feed[1] & " | " & $reactor.charge & "/" &
      $sim.config.chargeMax & " | " & ($sim.reactorStatus(index)).toUpperAscii &
      " | " & $reactor.feed[0] & " " & $reactor.stock[0] & ", " &
      $reactor.feed[1] & " " & $reactor.stock[1] & " | " &
      $sim.yieldNow(index) & " | " & $reactor.foodMade & "\n")

  result.add("\nMOLECULES:\nspecies | inert | loose | nearest to you\n")
  for species in sim.config.speciesPresent():
    let cells = sim.looseCells(species)
    var nearest = "none"
    var bestDistance = high(int)
    for cell in cells:
      let distance = manhattan(cell, cog.cell)
      if distance < bestDistance:
        bestDistance = distance
        nearest = "(" & $cell.x & "," & $cell.y & ")"
    result.add($species & " | " & (if species.isInert(): "YES" else: "no") &
      " | " & $cells.len & " | " & nearest & "\n")

  result.add("\nFOOD ON THE FLOOR: " & $sim.foodCells().len & "\n")

  result.add("\nCOGS:\nalias | cell | carrying | ate | delivered | hoard | " &
    "last job | last say\n")
  for other in 0 ..< Seats:
    let entry = sim.cogs[other]
    result.add(entry.alias & " | (" & $entry.cell.x & "," & $entry.cell.y &
      ") | " & (if entry.hasCarry: $entry.carrying else: "-") & " | " &
      $entry.foodEaten & " | " & $entry.delivered & " | " & $entry.hoard &
      " | " & $entry.order.job &
      (if entry.order.hasMolecule: " " & $entry.order.molecule else: "") &
      (if entry.order.hasReactor: " -> " & $entry.order.reactor else: "") &
      " | " & (if entry.say.len > 0: "\"" & entry.say & "\"" else: "-") & "\n")

  if sim.history.len > 0:
    result.add("\nSHIFT HISTORY:\nshift | reactions | food made | you ate | " &
      "cold starts | misdrops | charges\n")
    for record in sim.history:
      var reactions: seq[string]
      for value in record.reactions:
        reactions.add $value
      var made: seq[string]
      for value in record.foodMade:
        made.add $value
      var charges: seq[string]
      for value in record.charge:
        charges.add $value
      result.add($record.shift & " | " & reactions.join(",") & " | " &
        made.join(",") & " | " & $record.eaten[slot] & " | " &
        $record.coldStarts & " | " & $record.misdrops & " | " &
        charges.join(",") & "\n")

  result.add("\nYOUR NOTES FROM LAST SHIFT:\n" &
    (if cog.notes.len > 0: cog.notes else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"job\":\"" & $jobSupply & "\",\"molecule\":\"" &
    $sim.reactors[0].feed[0] & "\",\"reactor\":\"" & $sim.reactors[0].name &
    "\",\"say\":\"...\",\"notes\":\"...\"} - job one of " & legalJobs() &
    "; molecule one of " & sim.legalMolecules() & "; reactor one of " &
    sim.legalReactors() & "; say at most " & $MaxSayLen &
    " characters; notes at most " & $MaxNotesLen & " characters.")

# ---- Transport ---------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(ChemistryError,
      "no JSON object in response: " & errorText(head))
  parseJson(text[start .. stop])

proc parseDecision*(sim: Sim, payload: JsonNode): Order =
  ## The reply schema in `## Decisions`. An unknown job, a supply without a
  ## reactor, a missing molecule for supply/hoard, or a species whose vent is
  ## absent in this variant are all INVALID replies. A feedstock the named
  ## reactor does not take is accepted as written -- the misdrop is the graph
  ## test and must stay expressible.
  result.say = sayText(payload{"say"}.getStr())
  result.notes = notesText(payload{"notes"}.getStr())
  let jobNode = payload{"job"}
  if jobNode.isNil or jobNode.kind != JString:
    raise newException(ChemistryError, "no job in response")
  let job = parseJob(jobNode.getStr())
  if not job.ok:
    raise newException(ChemistryError,
      "unknown job: " & errorText(jobNode.getStr()))
  result.job = job.job
  let moleculeNode = payload{"molecule"}
  if not moleculeNode.isNil and moleculeNode.kind == JString and
      moleculeNode.getStr().strip().len > 0:
    let species = parseSpecies(moleculeNode.getStr())
    if not species.ok:
      raise newException(ChemistryError,
        "unknown molecule: " & errorText(moleculeNode.getStr()))
    result.molecule = species.species
    result.hasMolecule = true
  let reactorNode = payload{"reactor"}
  if not reactorNode.isNil and reactorNode.kind == JString and
      reactorNode.getStr().strip().len > 0:
    let reactor = parseReactorName(reactorNode.getStr())
    if not reactor.ok:
      raise newException(ChemistryError,
        "unknown reactor: " & errorText(reactorNode.getStr()))
    result.reactor = reactor.reactor
    result.hasReactor = true
  let normalized = sim.normalizeOrder(result)
  if not normalized.ok:
    raise newException(ChemistryError, normalized.error)
  result = normalized.order

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 rejects the whole request with a
    ## 400 when it is present.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string): string =
  if error.len > 0:
    raise newException(ChemistryError, "llm transport: " & errorText(error))
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(ChemistryError,
        "bedrock model access denied: " & errorText(detail))
    client.disabled = true
    raise newException(ChemistryError,
      "llm auth failed (" & $response.code & ") at " & url & ": " &
      errorText(detail))
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    raise newException(ChemistryError, "llm throttled (429): " &
      errorText(detail))
  if response.code < 200 or response.code >= 300:
    raise newException(ChemistryError, "anthropic error " & $response.code &
      ": " & errorText(response.body[0 .. min(response.body.high, 300)]))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(ChemistryError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(ChemistryError, "reply cut off at max_tokens before " &
      "any JSON: " & errorText(result[0 .. min(result.high, 160)]))

const RetryHint = "\nYour previous reply was invalid. Respond with ONLY " &
  "the requested JSON object, using one of the listed job, molecule and " &
  "reactor values."

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Order] =
  ## One standing order per seat, in slot order. Never raises: any failure
  ## falls back to the `courier` order so the episode always advances.
  result = newSeq[Order](Seats)
  var open: seq[int]
  for slot in 0 ..< Seats:
    let kind = scripted[slot]
    ## A seat that never connected, or whose socket died mid-episode, plays
    ## `courier` for every remaining shift: there is no operator behind it to
    ## prompt, so an LLM call would spend the budget on an empty guidance
    ## block. The server owns `connected`.
    if kind != skNone or client.disabled or not sim.cogs[slot].connected:
      result[slot] = sim.scriptedOrder(slot,
        (if kind == skNone: skCourier else: kind))
    else:
      open.add slot
  client.lastBatchSize = open.len
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    ## ALL open seats in ONE parallel batch -- never sequentially. This is
    ## what keeps 12 shifts inside the 720 s play budget.
    var batch: RequestBatch
    for slot in open:
      var user = sim.userPrompt(slot, prompts[slot])
      if attempt > 0:
        user.add(RetryHint)
      let request = client.requestFor(sim.systemPrompt(slot), user)
      batch.post(request.url, request.headers, request.body, $slot)
    if attempt == 0:
      client.lastBatchSize = batch.len
    let started = epochTime()
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    let latencyMs = int((epochTime() - started) * 1000.0)
    var stillOpen: seq[int]
    for position, slot in open:
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var order = sim.parseDecision(extractJsonObject(text))
        order.source = (if attempt == 0: osLlm else: osRetry)
        order.latencyMs = latencyMs
        result[slot] = order
      except CatchableError as error:
        echo "chemistry llm: seat ", slot, " attempt ", attempt, " failed: ",
          errorText(error.msg)
        stillOpen.add slot
    open = stillOpen
  for slot in open:
    echo "chemistry llm: seat ", slot, " falling back to scripted order"
    result[slot] = sim.courierOrder(slot)
    result[slot].source = osFallback
