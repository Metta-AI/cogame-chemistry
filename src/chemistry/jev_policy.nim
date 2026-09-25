## Jev ranks Chemistry's exact legal standing orders in the player container.

import std/[json, os, strutils, times]
import curly

var lastCall: float

proc chooseAction*(observation: JsonNode, guidance: string): JsonNode =
  var criteria = newJObject()
  for option in observation["legalOrders"]:
    let id = option["id"].getStr()
    criteria[id] = %($option)
  if criteria.len == 0 or criteria.len > 255:
    raise newException(ValueError, "Chemistry legal menu outside SystemOne limits")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint, model, key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Chemistry Jev has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Chemistry. Choose one exact standing order " &
      "using your seat observation. Supply feedstocks to keep the vats " &
      "reacting, or forage for food. Inert species do not feed a vat. " &
      guidance & "\nYour observation:\n" & $observation,
    "questions": {"order": {
      "type": "choice", "instructions": "Choose one exact legal order ID.",
      "criteria": criteria
    }}
  }
  let elapsed = epochTime() - lastCall
  if lastCall > 0 and elapsed < 2.1:
    sleep(((2.1 - elapsed) * 1000).int)
  lastCall = epochTime()
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 18)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["order"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected: string
  for id, node in probabilities.pairs:
    if not criteria.hasKey(id):
      raise newException(ValueError, "Jev returned an unknown order")
    let probability = node.getFloat()
    if probability < 0 or probability > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += probability
    if probability > best:
      best = probability
      selected = id
  if abs(total - 1) > criteria.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Chemistry Jev: order ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  %*{"type": "action", "orderId": selected}
