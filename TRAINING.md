# Metta post-training data

The native simulator and published `courier` policy export supervised examples
for all four certified variants:

```sh
nimby sync nimby.lock
for variant in two-cycles two-cycles-distractors three-cycles \
  three-cycles-plentiful-distractors; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/chemistry-$variant" 10 1 "$variant"
done
```

Each run reads its manifest variant config, adds the per-seat tokens supplied
by the hosted platform, and plays complete seeded episodes with the native
simulator. Examples contain the hosted system and user prompts, each seat's
observation, and a `courier` order accepted by the game's reply parser. Parsed
orders drive the simulator. Entire episodes stay in one split. The manifest
records source revision, variant, scores, wins, and row counts. Existing output
directories are never overwritten.

Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.


Ten complete episodes per variant yielded 768 training and 192 validation
examples each. All 3,840 examples fit a 4,096-token context with the
Qwen2.5-0.5B-Instruct tokenizer (maximum: 1,971 tokens). One CPU optimizer step
per dataset with a local tiny model verifies the Metta post-training path.
These examples distill the scripted teacher; they do not establish stronger
league play.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest and variant to Metta's
`recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/chemistry-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/chemistry-train-bridge
```

All four certified variants expose 216 numeric observation values and 25
fixed order slots. The catalog includes idle, forage, hoard, and supply
orders; absent species and reactors are masked. Numeric observations contain
the acting seat's position, public reactor and cog state, visible loose
molecules and food, and four resolved shifts of history. The semantic view
comes from the hosted player's observation. Both views remain frozen while
the eight seats decide simultaneously. The `courier` policy supplies opponents
and teacher labels. Complete games return native food-eaten scores. Hosted
prompts remain available to Metta post-training.

## Matched prompt collections

Append `FIRST_PROMPT_SEED` to the exporter command to cycle training wordings
separately within each split. Omitting it uses the manifest prompt configuration.
Episode IDs include requested selection, resolved wording, and prompt seed for
both paths. Scenario-family IDs stay unchanged across matched collections.


## Native model trace collection

The private `COGAME_SAVE_TRAJECTORY_URI` opt-in seals exact native model
requests and received response text alongside authoritative applied orders.
The existing Curly parallel batches, full observations, operator guidance,
private notes, ordinary shifts, native retries, parser, fallback and game rules
are preserved. Public results and replay are written after the private artifact.
Without the private upload URI no trajectory is created.

Every retry retains its actual request, generated response, received body,
platform call ID, decoder fields and per-attempt prompt hashes. Supplied text
never becomes a generated label. Responses whose native parser clamps reactor
choices or shortens speech/notes remain evidence but have no selected model
label. Existing scripted and unqualified external actions retain unknown origin;
they are not relabeled as model demonstrations or reviewed teachers. Deadline
endings are truncated rather than completed training episodes.

Use the maintained `metta-posttrain collect-hosted` and `prepare-hosted-data`
workflows for receipt-bound admission and Qwen mask auditing. Neither game
capture nor a completed hosted game establishes data eligibility or learning.
Source/image identity, exact provider receipts, prompt-bank exclusions, physical
family partitioning and full native learner deployment require separate review.

The complete system check runs all four manifest variants through loopback
inference, with capture enabled and disabled. It exercises native retries,
fallbacks, shortened/clamped actions, privacy, exact suffix/body equality and
identical complete-game outcomes, including ordinary natural famine endings:

```sh
nim c -r --path:src tests/test_native_capture.nim
```

These synthetic protocol responses qualify software behavior; they are not
real-model game traces and are never training data. Curly exposes decompressed
response bodies and parsed headers; the capture does not invent raw HTTP headers,
reader-state facts, token IDs or behavior likelihoods that it cannot observe.
