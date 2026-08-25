## The decision layer: tolerant parsing, the reply schema, and the guarantee
## that a broken transport never raises and never blocks the episode.

import std/[json, os, strutils, unicode, unittest]
import chemistry/sim
import chemistry/llm

proc freshSim(cycles = 3, distractorPeriod = 2): Sim =
  var config = defaultGameConfig()
  config.seed = 5
  config.cycles = cycles
  config.distractorPeriod = distractorPeriod
  config.distractorGroundCap = 24
  config.llmTimeoutSeconds = 5
  result = initSim(config)
  result.logEnabled = false

suite "extractJsonObject is tolerant":
  test "a markdown-fenced reply":
    let node = extractJsonObject("```json\n{\"job\":\"idle\"}\n```")
    check node{"job"}.getStr() == "idle"

  test "a prose-prefixed reply with trailing prose":
    let node = extractJsonObject(
      "Sure! Here is my order:\n{\"job\": \"forage\"}\nHope that helps.")
    check node{"job"}.getStr() == "forage"

  test "a reply with no object at all raises":
    expect ChemistryError:
      discard extractJsonObject("I would rather not say.")

suite "the reply schema":
  let sim = freshSim()

  test "an unknown job is invalid":
    expect ChemistryError:
      discard sim.parseDecision(parseJson("""{"job":"sabotage"}"""))

  test "a missing job is invalid":
    expect ChemistryError:
      discard sim.parseDecision(parseJson("""{"say":"hello"}"""))

  test "supply without a reactor is invalid":
    expect ChemistryError:
      discard sim.parseDecision(
        parseJson("""{"job":"supply","molecule":"resin"}"""))

  test "supply without a molecule is invalid":
    expect ChemistryError:
      discard sim.parseDecision(
        parseJson("""{"job":"supply","reactor":"amber"}"""))

  test "a species absent from this variant is invalid":
    let plain = freshSim(3, 0)
    expect ChemistryError:
      discard plain.parseDecision(parseJson(
        """{"job":"supply","molecule":"glitter","reactor":"amber"}"""))

  test "a reactor absent from this variant is CLAMPED, not rejected":
    var two = freshSim(2, 0)
    two.reactors[1].charge = 0
    let order = two.parseDecision(parseJson(
      """{"job":"supply","molecule":"spark","reactor":"cobalt"}"""))
    check order.clamped
    check order.hasReactor
    check order.reactor == rxBeryl

  test "a reactor absent from this variant is CLAMPED on forage too":
    ## The design's `reactor` row scopes the clamp to the field, not to the
    ## job: naming an absent vat on `forage` is recorded as clamped as well.
    var two = freshSim(2, 0)
    two.reactors[1].charge = 0
    let order = two.parseDecision(parseJson(
      """{"job":"forage","reactor":"cobalt"}"""))
    check order.job == jobForage
    check order.clamped
    check order.hasReactor
    check order.reactor == rxBeryl

  test "a feedstock the named reactor does not take is ACCEPTED as written":
    ## The misdrop is the graph test and must stay expressible.
    let order = sim.parseDecision(parseJson(
      """{"job":"supply","molecule":"brine","reactor":"amber"}"""))
    check order.job == jobSupply
    check order.molecule == spBrine
    check order.reactor == rxAmber
    check not order.clamped

  test "say and notes are cut on rune boundaries":
    let long = "\u00e9".repeat(500)
    let order = sim.parseDecision(%*{
      "job": "idle", "say": long, "notes": long})
    check order.say.len <= MaxSayLen * 4
    check order.notes.len <= MaxNotesLen * 4
    check validateUtf8(order.say) == -1
    check validateUtf8(order.notes) == -1

suite "degrade, never hang":
  test "with no credentials the client disables itself and every seat plays courier":
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    delEnv("ANTHROPIC_API_KEY")
    delEnv("ANTHROPIC_API_KEY_URI")
    let sim = freshSim()
    let client = newLlmClient(sim.config)
    check client.disabled
    var prompts = newSeq[string](Seats)
    var scripted = newSeq[ScriptKind](Seats)
    let orders = client.decideAll(sim, prompts, scripted)
    check orders.len == Seats
    for slot in 0 ..< Seats:
      check orders[slot].source == osScripted
      check sim.normalizeOrder(orders[slot]).ok

  test "a dead transport falls back to courier, marks the source, and never raises":
    ## A closed port on localhost is a transport that fails immediately: the
    ## same path a timeout, a 429, a 403 or a junk body takes.
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:9/bedrock")
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "not-a-real-token")
    defer:
      delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
      delEnv("AWS_BEARER_TOKEN_BEDROCK")
    let sim = freshSim()
    let client = newLlmClient(sim.config)
    check not client.disabled
    var prompts = newSeq[string](Seats)
    for slot in 0 ..< Seats:
      prompts[slot] = "hold your lane"
    var scripted = newSeq[ScriptKind](Seats)
    let orders = client.decideAll(sim, prompts, scripted)
    ## ONE batch carries every open seat -- eight on shift 1.
    check client.lastBatchSize == Seats
    for slot in 0 ..< Seats:
      check orders[slot].source == osFallback
      let courier = sim.courierOrder(slot)
      check orders[slot].job == courier.job
      check orders[slot].hasMolecule == courier.hasMolecule
      if courier.hasMolecule:
        check orders[slot].molecule == courier.molecule

  test "scripted seats never enter the batch":
    let sim = freshSim()
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    putEnv("ANTHROPIC_API_KEY", "sk-test-not-real")
    defer: delEnv("ANTHROPIC_API_KEY")
    let client = newLlmClient(sim.config)
    check not client.disabled
    var prompts = newSeq[string](Seats)
    var scripted = newSeq[ScriptKind](Seats)
    for slot in 0 ..< Seats:
      scripted[slot] = (if slot mod 2 == 0: skCourier else: skFreeloader)
    let orders = client.decideAll(sim, prompts, scripted)
    check client.lastBatchSize == 0
    for slot in 0 ..< Seats:
      check orders[slot].source == osScripted

suite "the observation and the prompts":
  let sim = freshSim()

  test "the observation carries the room but never another seat's secrets":
    let node = sim.observationJson(3)
    check node{"protocol"}.getStr() == "chemistry.player.v1"
    check node{"slot"}.getInt() == 3
    check node{"name"}.getStr() == SeatAliases[3]
    check node{"cogs"}.len == Seats
    check node{"reactors"}.len == sim.reactors.len
    check node{"rules"}{"reactions"}.len == sim.reactors.len
    let text = $node
    ## Aliases in-game; no policy name, player name or account ever reaches a
    ## seat.
    for alias in SeatAliases:
      check alias in text
    check "chemistry-foreman" notin text
    check "daveey" notin text
    ## Only the seat's OWN notes are present.
    check node{"notes"}.kind == JString

  test "the prompts name the legal enum values for THIS variant":
    let two = freshSim(2, 0)
    let user = two.userPrompt(0, "operator guidance here")
    check "operator guidance here" in user
    check "cobalt" notin user
    check "glitter" notin user
    let system = two.systemPrompt(0)
    check "ARGON" in system
    check "reply with ONLY one JSON object" in system
    check "begin with the character {" in system
    check "supply | forage | hoard | idle" in system
