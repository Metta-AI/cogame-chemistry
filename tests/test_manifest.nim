## Packaging: the manifest template, the compose service name it derives its
## image placeholder from, and the certification fixture.

import std/[json, os, sequtils, strutils, unittest]
import chemistry/sim

const RepoRoot = currentSourcePath().parentDir().parentDir()

proc readManifest(): JsonNode =
  parseJson(readFile(RepoRoot / "coworld_manifest_template.json"))

proc composeServiceName(): string =
  ## `coworld build` derives the manifest's image placeholder from the COMPOSE
  ## service name (`service lantern` -> `{{LANTERN_IMAGE}}`), and hard-fails on
  ## anything else (lantern 0.1.0, 2026-08-23).
  var inServices = false
  for line in readFile(RepoRoot / "compose.yaml").splitLines():
    if line.startsWith("services:"):
      inServices = true
      continue
    if inServices and line.len > 2 and line[0] == ' ' and line[1] == ' ' and
        line[2] != ' ' and line.strip().endsWith(":"):
      return line.strip().strip(chars = {':'})
  ""

suite "manifest":
  let manifest = readManifest()
  let game = manifest["game"]

  test "the top level carries what coworld 0.1.42 requires":
    check manifest.hasKey("$schema")
    check manifest{"tags"}.len >= 3
    check manifest{"episode_timeout_minutes"}.getInt() > 0
    check manifest{"player"}.len >= 1
    check game{"runnable"}{"type"}.getStr() == "game"

  test "the image placeholder is the one derived from compose.yaml":
    let service = composeServiceName()
    check service == "chemistry"
    let expected = "{{" & service.toUpperAscii() & "_IMAGE}}"
    check game{"runnable"}{"image"}.getStr() == expected
    for entry in manifest{"player"}:
      check entry{"image"}.getStr() == expected

  test "the replay viewer is the STATIC bundle, never a pod":
    check game{"replay_viewer"}{"bundle"}.getStr() == "static-replay-viewer"

  test "the game runnable carries the coworld secret URI":
    ## Without it the hosted game container never sees the secret and every
    ## league episode silently plays scripted (hive, 2026-08-23).
    check game{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
      "secret://coworld/chemistry/anthropic_api_key"

  test "docs are TEXT and carry pages":
    check game{"docs"}{"readme"}{"type"}.getStr() == "text"
    check game{"docs"}{"readme"}{"value"}.getStr().len > 200
    check game{"docs"}{"pages"}.len >= 2
    for page in game{"docs"}{"pages"}:
      check page{"id"}.getStr().len > 0
      check page{"title"}.getStr().len > 0
      check page{"content"}{"type"}.getStr() == "text"
      check page{"content"}{"value"}.getStr().len > 100

  test "BOTH protocols are present and both are text objects":
    ## The platform validator rejects bare strings (cogame-garble v0.1.0).
    for name in ["player", "global"]:
      let node = game{"protocols"}{name}
      check node.kind == JObject
      check node{"type"}.getStr() == "text"
      check node{"value"}.getStr().len > 100

  test "every array property in config_schema is bounded":
    ## Cert fails `manifest_invalid` on an array without minItems/maxItems
    ## (tandem 0.1.0, 2026-08-23).
    let properties = game{"config_schema"}{"properties"}
    check game{"config_schema"}{"required"}.getElems().anyIt(
      it.getStr() == "tokens")
    check game{"config_schema"}{"additionalProperties"}.getBool() == false
    for name, property in properties:
      if property{"type"}.getStr() == "array":
        check property.hasKey("minItems")
        check property.hasKey("maxItems")
    for name, property in game{"results_schema"}{"properties"}:
      if property{"type"}.getStr() == "array":
        check property.hasKey("minItems")
        check property.hasKey("maxItems")

  test "config_schema declares every field the game actually reads":
    let properties = game{"config_schema"}{"properties"}
    for name in ["tokens", "players", "num_agents", "seed", "cycles",
                 "shifts", "ticksPerShift", "moveCooldown", "carryCap",
                 "ventPeriod", "ventGroundCap", "distractorPeriod",
                 "distractorGroundCap", "chargeMax", "charge0",
                 "chargeDecayPeriod", "reactionCooldown", "coldStartCost",
                 "foodLifetime", "llmTimeoutSeconds", "minTurnSeconds",
                 "maxOutputTokens", "model", "episodeTimeoutSeconds",
                 "playerConnectTimeoutSeconds", "shutdownGraceSeconds",
                 "showPlayerLabels"]:
      check properties.hasKey(name)

  test "num_agents is 8 in EVERY variant":
    check manifest{"variants"}.len == 4
    var ids: seq[string]
    for variant in manifest{"variants"}:
      check variant{"description"}.getStr().len > 20
      check variant{"name"}.getStr().len > 0
      check variant{"game_config"}{"num_agents"}.getInt() == Seats
      check variant{"game_config"}{"players"}.len == Seats
      ids.add variant{"id"}.getStr()
    check ids == @["two-cycles", "two-cycles-distractors", "three-cycles",
                   "three-cycles-plentiful-distractors"]

  test "the variant table matches what the sim derives":
    for variant in manifest{"variants"}:
      var config = defaultGameConfig()
      config.update($variant{"game_config"})
      check config.variantId() == variant{"id"}.getStr()

  test "the certification fixture carries num_agents and seats every player":
    let cert = manifest{"certification"}
    check cert{"game_config"}{"num_agents"}.getInt() == Seats
    check cert{"game_config"}{"players"}.len == Seats
    check cert{"players"}.len == Seats
    var seated: seq[string]
    for entry in cert{"players"}:
      seated.add entry{"player_id"}.getStr()
    ## `players-run` seats the whole roster: a fixture of baseline x N fails
    ## `players_missing` (raid, 2026-08-23).
    for entry in manifest{"player"}:
      check entry{"id"}.getStr() in seated

  test "the certification fixture fits certify's 60 s default and outlasts the soak":
    let config = manifest{"certification"}{"game_config"}
    let ticks = config{"shifts"}.getInt() * config{"ticksPerShift"}.getInt()
    let seconds = ticks div TargetFps
    ## Longer than the 10 s viewer soak (ecos, 2026-08-23)...
    check seconds >= 12
    ## ...and short enough that grace + rounds + linger stays inside
    ## `coworld certify --timeout-seconds 60` (commons-family, 2026-08-24).
    check config{"minTurnSeconds"}.getInt() == 0
    check seconds <= 25

suite "policies":
  let policies = parseJson(readFile(RepoRoot / "tools" / "ci" / "policies.json"))

  test "two prompt champions and two scripted fillers, all one image":
    check policies.len == 4
    var prompts = 0
    var scripts = 0
    for policy in policies:
      check policy{"run"}.getStr() == "/bin/chemistry-player"
      if policy{"env"}.hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 200
        ## Without USE_BEDROCK the platform gives the player pod no Bedrock
        ## sidecar and the seat silently plays scripted (cogolf, 2026-08-24).
        check policy{"env"}{"USE_BEDROCK"}.getStr() == "true"
      if policy{"env"}.hasKey("PLAYER_SCRIPTED"):
        inc scripts
        check parseScriptKind(policy{"env"}{"PLAYER_SCRIPTED"}.getStr()) !=
          skNone
    check prompts == 2
    check scripts == 2

  test "champion #2 is owned by daveey-1":
    check policies[1]{"name"}.getStr() == "chemistry-metabolist"
    check policies[1]{"player"}.getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    ## Filler versions must differ from champion versions.
    var names: seq[string]
    for policy in policies:
      names.add policy{"name"}.getStr()
    check names.deduplicate().len == names.len
