## Export complete native Chemistry episodes as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import chemistry/[sim, llm, scripted]

const OperatorPrompt = "Feed the reactors and maximize your own food eaten."
const Variants = ["two-cycles", "two-cycles-distractors", "three-cycles",
                  "three-cycles-plentiful-distractors"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "two-cycles"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    config.update($runtimeConfig)
    config.seed = seed
    var sim = initSim(config)
    sim.logEnabled = false
    var rows: seq[string]
    while not sim.done:
      for seat in 0 ..< sim.seats():
        let teacher = sim.scriptedOrder(seat, skCourier)
        var completion = %*{
          "job": $teacher.job, "say": teacher.say, "notes": teacher.notes
        }
        if teacher.hasMolecule:
          completion["molecule"] = %($teacher.molecule)
        if teacher.hasReactor:
          completion["reactor"] = %($teacher.reactor)
        let parsed = sim.parseDecision(completion)
        doAssert parsed.job == teacher.job
        doAssert parsed.hasMolecule == teacher.hasMolecule
        doAssert parsed.hasReactor == teacher.hasReactor
        if teacher.hasMolecule:
          doAssert parsed.molecule == teacher.molecule
        if teacher.hasReactor:
          doAssert parsed.reactor == teacher.reactor
        rows.add($(%*{
          "episode_id": "chemistry-" & variant & "-" & $seed,
          "seed": "chemistry-" & variant & "-" & $seed,
          "decision_id": sim.shift * sim.seats() + seat,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, seat)},
            {"role": "user", "content": userPrompt(sim, seat, OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "chemistry",
          "action_schema_revision": "chemistry-order-v1"
        }))
        sim.applyOrder(seat, parsed)
      sim.runShift()
    doAssert rows.len > 0 and sim.reason == erComplete
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "win": outcome["win"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "chemistry",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-courier",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
