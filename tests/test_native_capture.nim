## Complete ordinary simulator episodes through the unchanged parallel HTTP path.
import std/[json, os, osproc, streams, strutils, tempfiles]
import chemistry/[sim, llm, training]

proc run(variant, destination: string): JsonNode =
  let provider = startProcess("python3", args = [
    currentSourcePath().parentDir() / "native_capture_provider.py"],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    provider.terminate()
    discard provider.waitForExit(5000)
    provider.close()
  let port = provider.outputStream.readLine()
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:" & port)
  putEnv("COWORLD_LLM_MODEL", "native-capture-fixture")
  putEnv("COWORLD_EPISODE_ID", "capture-" & variant)
  putEnv("COWORLD_GAME_VERSION", "fixture")
  putEnv("COWORLD_SOURCE_REVISION", repeat('a', 40))
  if destination.len > 0: putEnv("COGAME_SAVE_TRAJECTORY_URI", "file://" & destination)
  else: delEnv("COGAME_SAVE_TRAJECTORY_URI")
  var config = defaultGameConfig()
  let manifest = parseFile(currentSourcePath().parentDir().parentDir() / "coworld_manifest_template.json")
  for item in manifest["variants"]:
    if item["id"].getStr() == variant: config.update($item["game_config"])
  config.seed = 42
  config.llmTimeoutSeconds = 5
  var game = initSim(config)
  game.logEnabled = false
  for seat in 0 ..< Seats: game.cogs[seat].connected = true
  let trajectory = initNativeTrajectory(config)
  let client = newLlmClient(config)
  var operators = newSeq[string](Seats)
  for seat in 0 ..< Seats: operators[seat] = "Feed reactors; PRIVATE_OPERATOR_" & $seat
  while not game.done:
    let shift = game.shift
    var views: seq[JsonNode]
    for seat in 0 ..< Seats:
      let view = game.observationJson(seat)
      view["prompt_template"] = promptMetadata(config,
        systemPrompt(game, seat), userPrompt(game, seat, operators[seat]))
      views.add(view)
    let orders = client.decideAll(game, operators, newSeq[ScriptKind](Seats))
    for seat in 0 ..< Seats:
      game.applyOrder(seat, orders[seat])
      if not trajectory.isNil:
        trajectory.recordAppliedDecision(config, shift, seat, game.policyNames[seat],
          views[seat], game.cogs[seat].order, client.nativeAttempts[seat])
    game.runShift()
  trajectory.finishNativeTrajectory(game)
  result = game.resultsJson()
  if destination.len > 0:
    let lines = readFile(destination).strip().splitLines()
    doAssert result["shifts"].getInt() >= 3
    doAssert result["shifts"].getInt() <= config.shifts
    doAssert lines.len == result["shifts"].getInt() * Seats + 1
    let first = parseJson(lines[0])
    doAssert first["attempts"].len == 2
    doAssert not first["attempts"][0]["accepted"].getBool()
    let accepted = first["attempts"][1]
    doAssert accepted["accepted"].getBool()
    doAssert accepted["platform_call_id"].getStr().len == 36
    doAssert accepted["response"] == parseJson(accepted["raw_response"].getStr())["content"][0]["text"]
    doAssert accepted["behavior_logprobs"].kind == JNull
    doAssert accepted["prompt"][0]["content"] == accepted["request"]["system"]
    doAssert first["observation"]["prompt_attempts"][0]["prompt_template"]["user_sha256"] != first["observation"]["prompt_attempts"][1]["prompt_template"]["user_sha256"]
    for seat in 0 ..< Seats:
      let firstSeat = parseJson(lines[seat])
      let user = firstSeat["attempts"][1]["request"]["messages"][0]["content"].getStr()
      doAssert "PRIVATE_OPERATOR_" & $seat in user
      for other in 0 ..< Seats:
        if other != seat: doAssert "PRIVATE_OPERATOR_" & $other notin user
    let missingUsage = parseJson(lines[3 * Seats])["attempts"][0]
    doAssert missingUsage["accepted"].getBool()
    doAssert missingUsage["input_tokens"].kind == JNull
    doAssert missingUsage["output_tokens"].kind == JNull
    let fallback = parseJson(lines[Seats])
    doAssert fallback["action_status"].getStr() == "fallback"
    doAssert fallback["selected_attempt_id"].kind == JNull
    doAssert fallback["attempts"].len == 2
    let normalized = parseJson(lines[2 * Seats])
    doAssert normalized["action_status"].getStr() == "rejected"
    doAssert normalized["selected_attempt_id"].kind == JNull
    let last = parseJson(lines[^1])
    doAssert last["status"].getStr() == "completed"
    doAssert last["outcome"] == result
    doAssert last["seed_family"].getStr() == "chemistry-42"
    doAssert (getFilePermissions(destination) * {fpOthersRead, fpGroupRead}) == {}

let output = createTempDir("chemistry-native-capture-", "")
for variant in ["two-cycles", "two-cycles-distractors", "three-cycles", "three-cycles-plentiful-distractors"]:
  let captured = run(variant, output / (variant & ".jsonl"))
  let ordinary = run(variant, "")
  doAssert captured == ordinary, "private capture changed ordinary game outcomes"
echo "eight complete native games: capture on/off outcomes match; retries, fallbacks, normalization and private source evidence pass"
