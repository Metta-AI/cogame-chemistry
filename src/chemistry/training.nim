## Private native-model evidence; rules, prompts, transport and parsing stay game-owned.
import std/[json, options, os, strutils]
import bitworld/decision_trajectory
import curly, crunchy
import sim, prompts
export decision_trajectory

proc orderAction*(order: Order): JsonNode =
  result = %*{"job": $order.job, "say": order.say, "notes": order.notes}
  if order.hasMolecule: result["molecule"] = %($order.molecule)
  if order.hasReactor: result["reactor"] = %($order.reactor)

proc nativeScenarioFamily*(config: GameConfig): string =
  # The v1 kernel never consumes its seeded RNG. Replay rule/state descriptors
  # identify physical scenarios; seed, wording and presentation do not.
  let physical = config.configJson()
  physical.delete("cell")
  physical.delete("showPlayerLabels")
  if config.distractorPeriod <= 0:
    physical["distractorGroundCap"] = %0
  "chemistry-physical-v1-" & sha256($physical).toHex.toLowerAscii()

proc initNativeTrajectory*(config: GameConfig): DecisionTrajectory =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"), nativeScenarioFamily(config),
    "chemistry", getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"))

proc nativeAttempt*(policy: string, shift, seat, retry: int, body: string): DecisionAttempt =
  result = newDecisionAttempt($shift & "-" & $seat & "-attempt-" & $retry, policy, aoModel)
  result.request = parseJson(body)
  result.prompt = %*[{"role": "system", "content": result.request["system"]}]
  for message in result.request["messages"]: result.prompt.add(copy(message))
  result.decoder = newJObject()
  for key, value in result.request:
    if key notin ["model", "system", "messages", "anthropic_version"]:
      result.decoder[key] = copy(value)

proc receiveNativeResponse*(attempt: var DecisionAttempt, response: Response,
    transportError: string, latencyMs: int) =
  # Curly returns received, decompressed body bytes and parsed headers. Do not
  # manufacture a raw HTTP header block or claim unexposed transport facts.
  attempt.rawResponse = %response.body
  attempt.latencyMs = some(latencyMs.float)
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    let value = response.headers[header]
    if value.len > 0:
      case field
      of "call": attempt.platformCallId = some(value)
      of "model": attempt.modelIdentity = some(value)
      of "tokenizer": attempt.tokenizerIdentity = some(value)
      of "template": attempt.chatTemplateSha256 = some(value)
  if transportError.len > 0 or response.code < 200 or response.code >= 300: return
  let payload = parseJson(response.body)
  if payload.hasKey("model") and payload["model"].kind == JString:
    attempt.model = some(payload["model"].getStr())
  if payload.hasKey("stop_reason") and payload["stop_reason"].kind == JString:
    attempt.stopReason = some(payload["stop_reason"].getStr())
  let usage = payload{"usage"}
  if not usage.isNil and usage.kind == JObject:
    if usage.hasKey("input_tokens") and usage["input_tokens"].kind == JInt: attempt.inputTokens = some(usage["input_tokens"].getInt())
    if usage.hasKey("output_tokens") and usage["output_tokens"].kind == JInt: attempt.outputTokens = some(usage["output_tokens"].getInt())
  var text = ""
  for part in payload["content"]:
    if part{"type"}.getStr() == "text": text.add(part{"text"}.getStr())
  attempt.response = %text

proc recordAppliedDecision*(trajectory: DecisionTrajectory, config: GameConfig,
    shift, seat: int, policy: string, observation: JsonNode, order: Order,
    evidence: seq[DecisionAttempt]) =
  if trajectory.isNil: return
  let action = order.orderAction()
  var attempts = evidence
  var selected = none(string)
  var status = asAccepted
  var fallback = none(string)
  case order.source
  of osLlm, osRetry:
    doAssert attempts.len > 0 and attempts[^1].parsedAction == action
    if attempts[^1].accepted: selected = some(attempts[^1].attemptId)
    else: status = asRejected
  of osFallback:
    status = asFallback
    fallback = some("engine-courier")
    for attempt in attempts.mitems: attempt.accepted = false
  of osScripted, osExternal:
    # Existing scripted/external actions have no authenticated model evidence.
    # Preserve execution without granting them teacher or model authority.
    var attempt = newDecisionAttempt($shift & "-" & $seat & "-unknown",
      policy, aoUnknown)
    attempt.parsedAction = action
    attempt.accepted = true
    attempts.add(attempt)
    selected = some(attempt.attemptId)
  var view = copy(observation)
  view["prompt_attempts"] = newJArray()
  for attempt in attempts:
    if attempt.origin == aoModel:
      view["prompt_attempts"].add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": promptMetadata(config,
          attempt.request["system"].getStr(),
          attempt.request["messages"][0]["content"].getStr())})
  trajectory.recordDecision($shift & "-" & $seat, $seat, view,
    attempts, selected, action, status, fallbackOrigin = fallback)

proc finishNativeTrajectory*(trajectory: DecisionTrajectory, game: Sim) =
  if trajectory.isNil: return
  let outcome = game.resultsJson()
  var scores = newJObject()
  for seat in 0 ..< Seats: scores[$seat] = outcome["scores"][seat]
  trajectory.finish(if outcome["reason"].getStr() == "complete": esCompleted else: esTruncated,
    outcome, scores)
  trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
