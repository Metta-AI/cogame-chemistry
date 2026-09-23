## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:chemistry-train-bridge tools/train_bridge.nim

import std/[json, os]
import chemistry/[llm, sim]

const OperatorPrompt = "Feed the reactors and maximize your own food eaten."
const ActionSlots = 1 + 1 + 3 + 5 + 5 * 3

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc actionOf(order: Order): JsonNode =
  result = %*{"job": $order.job}
  if order.hasMolecule:
    result["molecule"] = %($order.molecule)
  if order.hasReactor:
    result["reactor"] = %($order.reactor)

proc decision(view: Sim, id, seat: int): JsonNode =
  %*{
    "kind": "decision", "game": "chemistry", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view.shift,
    "semantic_view": observationJson(view, seat),
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(view, seat)},
      {"role": "user", "content": userPrompt(view, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["job"]},
    "typed_question": newJNull()
  }

proc encoding(view: Sim, id, seat: int): JsonNode =
  var values = newJArray()
  for other in 0 ..< Seats:
    values.add(%(if seat == other: 1 else: 0))
  for value in [view.shift, view.config.shifts, view.tick,
      view.config.ticksPerShift]:
    values.add(%value)
  let me = view.cogs[seat]
  values.add(%me.cell.x)
  values.add(%me.cell.y)
  values.add(%(if me.hasCarry: ord(me.carrying) else: -1))
  for reactorName in ReactorName:
    var found = false
    for reactor in view.reactors:
      if reactor.name == reactorName:
        found = true
        for value in [1, reactor.charge, reactor.stock[0],
            reactor.stock[1], reactor.cooldown, reactor.foodMade]:
          values.add(%value)
    if not found:
      for field in 0 ..< 6:
        values.add(%0)
  for other in 0 ..< Seats:
    let cog = view.cogs[other]
    for value in [cog.cell.x, cog.cell.y,
        (if cog.hasCarry: ord(cog.carrying) else: -1),
        cog.foodEaten, cog.delivered, cog.misdrops, cog.hoard,
        ord(cog.order.job),
        (if cog.order.hasMolecule: ord(cog.order.molecule) else: -1),
        (if cog.order.hasReactor: ord(cog.order.reactor) else: -1)]:
      values.add(%value)
  let visible = observationJson(view, seat)
  for species in Species:
    if view.config.hasSpecies(species):
      let molecule = visible["molecules"][$species]
      values.add(%1)
      values.add(molecule["loose"])
      if molecule["nearestToYou"].kind == JNull:
        values.add(%(-1))
        values.add(%(-1))
      else:
        values.add(molecule["nearestToYou"][0])
        values.add(molecule["nearestToYou"][1])
    else:
      for field in 0 ..< 4:
        values.add(%0)
  values.add(visible["food"]["loose"])
  var nearest = Cell(x: -1, y: -1)
  var distance = high(int)
  for cell in visible["food"]["cells"]:
    let point = Cell(x: cell[0].getInt(), y: cell[1].getInt())
    let d = manhattan(me.cell, point)
    if d < distance:
      nearest = point
      distance = d
  values.add(%nearest.x)
  values.add(%nearest.y)
  for offset in countdown(3, 0):
    let index = view.history.len - 1 - offset
    if index < 0:
      for field in 0 ..< 20:
        values.add(%0)
    else:
      let record = view.history[index]
      values.add(%record.shift)
      for reactorName in ReactorName:
        let slot = ord(reactorName)
        values.add(%(if slot < record.reactions.len:
          record.reactions[slot] else: 0))
        values.add(%(if slot < record.foodMade.len:
          record.foodMade[slot] else: 0))
      for eaten in record.eaten:
        values.add(%eaten)
      values.add(%record.coldStarts)
      values.add(%record.misdrops)
      for reactorName in ReactorName:
        let slot = ord(reactorName)
        values.add(%(if slot < record.charge.len:
          record.charge[slot] else: 0))
  var actions = newJArray()
  actions.add(actionOf(Order(job: jobIdle)))
  actions.add(actionOf(Order(job: jobForage)))
  for reactor in ReactorName:
    let order = Order(job: jobForage, reactor: reactor, hasReactor: true)
    actions.add(if view.config.hasReactor(reactor): actionOf(order)
      else: newJNull())
  for species in Species:
    let order = Order(job: jobHoard, molecule: species, hasMolecule: true)
    actions.add(if view.config.hasSpecies(species): actionOf(order)
      else: newJNull())
  for species in Species:
    for reactor in ReactorName:
      let order = Order(job: jobSupply, molecule: species,
        hasMolecule: true, reactor: reactor, hasReactor: true)
      actions.add(if view.config.hasSpecies(species) and
          view.config.hasReactor(reactor): actionOf(order)
        else: newJNull())
  doAssert actions.len == ActionSlots
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: chemistry-train-bridge MANIFEST [VARIANT]", 1)
  let variant = if args.len == 2: args[1] else: "two-cycles"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var view: Sim
  var id = 0
  var seat = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7"]
      config.update($runtimeConfig)
      config.seed = seedOf(request["seed"].getStr())
      game = initSim(config)
      game.logEnabled = false
      view = game
      id = 0
      seat = 0
      response = view.decision(id, seat)
    of "encode":
      doAssert not game.done
      response = view.encoding(id, seat)
    of "teacher":
      doAssert not game.done
      let teacher = view.scriptedOrder(seat, skCourier)
      response = %*{"response": $actionOf(teacher)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let parsed = view.parseDecision(action)
      game.applyOrder(seat, parsed)
      inc id
      var observation: JsonNode
      if seat == Seats - 1:
        game.runShift()
        if game.done:
          let outcome = game.resultsJson()
          var scores = newJObject()
          for slot in 0 ..< Seats:
            scores[$slot] = outcome["scores"][slot]
          observation = %*{"kind": "terminal", "scores": scores}
        else:
          view = game
          seat = 0
          observation = view.decision(id, seat)
      else:
        inc seat
        observation = view.decision(id, seat)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
