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

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/chemistry-two-cycles \
  --output /tmp/chemistry-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete episodes per variant yielded 768 training and 192 validation
examples each. All 3,840 examples fit a 4,096-token context with the
Qwen2.5-0.5B-Instruct tokenizer (maximum: 1,971 tokens). One CPU optimizer step
per dataset with a local tiny model verifies the Metta post-training path.
These examples distill the scripted teacher; they do not establish stronger
league play.
