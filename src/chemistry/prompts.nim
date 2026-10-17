## Episode wording and private message hashes, independent of music RNG.
import std/[json, strutils]
import crunchy
import sim_config

const PromptBankVersion* = "chemistry-rules-v1"
const Templates = [
  staticRead("prompts/plain.txt"), staticRead("prompts/numbered.txt"),
  staticRead("prompts/questions.txt"), staticRead("prompts/reordered.txt"),
  staticRead("prompts/heldout-briefing.txt"), staticRead("prompts/heldout-reference.txt")
]

proc renderVariantPrompt*(config: GameConfig, parts: openArray[string]): string =
  Templates[ord(config.selectedPromptVariant) - 1] % parts

proc promptMetadata*(config: GameConfig, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $config.selectedPromptVariant,
    "selection": $config.promptVariant, "seed": config.promptSeed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}
