## Chemistry entrypoint: reads the Coworld runtime contract and starts the
## episode server.
##
## Forked from `coworld-ctf/src/ctf.nim`. Seed randomisation happens HERE,
## BEFORE `config.update`, so every seed-derived draw follows the final seed
## (paintbot's rule).

import
  std/[json, strutils, sysrand],
  bitworld/runtime,
  chemistry/server,
  chemistry/sim

proc randomSeed(): int =
  var buffer: array[4, byte]
  if not urandom(buffer):
    raise newException(ChemistryError, "OS entropy source unavailable")
  (int(buffer[0]) shl 24 or int(buffer[1]) shl 16 or
    int(buffer[2]) shl 8 or int(buffer[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.strip().len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  ## Seed FIRST, config.update second: a draw made before the final seed is
  ## settled is not reproducible from the recorded seed.
  if not seedPinned(runtimeConfig.config):
    config.seed = randomSeed()
    echo "chemistry: seed not pinned; randomized"
  config.update(runtimeConfig.config)
  if not seedPinned(runtimeConfig.config):
    ## `config.update` never touches `seed` unless the JSON carries one, so
    ## the randomised value above survives; restate it for the log.
    echo "chemistry: seed ", config.seed
  echo "chemistry: seats=", config.numAgents,
    " variant=", config.variantId(),
    " shifts=", config.shifts,
    " ticksPerShift=", config.ticksPerShift
  runGameServer(config, runtimeConfig)
