# cogame-chemistry

**MP Chemistry — keep three autocatalytic food cycles fed while the room is full
of shiny useless molecules.**

Eight cogs share one 32×18 lab floor. Three vats each take a *distinct pair* of
feedstocks — amber wants `resin + spark`, beryl `spark + brine`, cobalt
`resin + brine` — so every feedstock serves two vats and who covers which lane
is a real decision, not a fixed assignment. A vat with `charge ≥ 1` and both
stocks ≥ 1 consumes one of each, gains a charge and drops `1 + charge div 3`
FOOD tokens on its spill ring, **nearest the cog that delivered the molecule
which triggered the reaction**. Charge is the catalyst and it decays once a
shift, so "running" is a state you *hold*. A vat that reaches charge 0 needs
three of **each** feedstock to restart and makes no food doing it — six
deliveries of pure investment.

Two of the five species, `glitter` and `quartz`, are **inert**. They can be
carried and hoarded and they do nothing at all; dropping one on a vat destroys
it. Reading the reaction graph is the skill.

**Your score is the number of food tokens YOU eat.** Nothing else is ranked.
Food is eaten automatically by standing on it, so camping a spill ring is a
strategy and shirking is a temptation — but three cycles need six supply lanes
and there are only eight seats, so two cogs may shirk for free and a third
breaks the room. A floor of eight shirkers watches every cycle go cold and
scores near zero for everyone.

## A policy is just a prompt

Once per 60-tick **shift** the game sends each seat its whole view of the room
plus that seat's `PLAYER_PROMPT` to Claude — **all eight seats in ONE parallel
batch** — and gets back one standing order:

```json
{"job":"supply","molecule":"resin","reactor":"cobalt",
 "say":"Cobalt is cold - I bring resin, someone bring brine",
 "notes":"amber at 7 and safe; cobalt died in shift 3 because nobody covered brine"}
```

A deterministic **courier kernel** turns that order into the per-tick grid
actions (`move_n` · `move_s` · `move_e` · `move_w` · `take` · `drop` · `wait`)
for the whole shift. Field your own policy by reusing the published player
runnable:

```bash
coworld upload-policy <chemistry-image> --name my-chemistry \
  --run /bin/chemistry-player \
  --secret-env PLAYER_PROMPT="<your strategy>" \
  --secret-env USE_BEDROCK=true
```

Two scripted baselines ship in the **same image**, env-switched:
`PLAYER_SCRIPTED=courier` (the working baseline, and the fallback every failed
LLM decision lands on) and `PLAYER_SCRIPTED=freeloader` (the shirker). With no
LLM credentials at all every seat plays `courier`, so offline certification
still completes.

## Variants

| id | cycles | distractors | seats |
|---|---|---|---|
| `two-cycles` | amber, beryl | none | 8 |
| `two-cycles-distractors` | amber, beryl | ordinary | 8 |
| `three-cycles` | all three | none | 8 |
| `three-cycles-plentiful-distractors` | all three | plentiful | 8 |

`three-cycles-plentiful-distractors` is the league default: it is the config
where reading the reaction graph beats grabbing the nearest shiny object.

## Layout

- `src/chemistry.nim` — the server entrypoint. **Seed randomisation happens
  here, before `config.update`**, so every seed-derived draw follows the final
  seed.
- `src/chemistry/` — the sim, split the way paintbot splits `src/ctf/`:
  `sim_types.nim` (consts + wire types; field order is sacred),
  `room.nim` (the authored grid + the BFS the kernel walks),
  `sim_config.nim`, `sim_state.nim`, `events.nim`, `kernel.nim` (the courier
  kernel), `scripted.nim` (the two baselines), `sim.nim` (the nine numbered
  tick-resolution steps), `llm.nim` (the batched decision layer, forked from
  `cogame-bullwhip`), `broadcast.nim`, `replays.nim`, `global.nim` (the
  sprite-protocol board renderer), `server.nim`, `wire_constants.nim`.
- `src/chemistry_player.nim` — the thin prompt-carrying player (forked from
  `cogame-bullwhip/src/bullwhip_player.nim`).
- `client/` — the viewer chrome. `chrome_common.js` is `Metta-AI/coworld-ctf`'s
  file **byte for byte**; `replay_broadcast.html` is that starter's page with a
  Chemistry game block appended under a banner comment.
- `replay-viewer/` — the static wasm bundle. All four files come from
  `coworld-ctf` and were renamed together.
- `scripts/art/` — the nano-banana source sheets, the keyer/splitter and the
  tile generator. `data/` holds the committed board art.
- `tests/` — the sim units, the baseline legality gate, the feasibility oracle,
  the end-to-end replay + strict-UTF-8 gate, the decision layer, the manifest
  and the chrome frame.

## Building and testing

The whole toolchain is pinned by `nimby.lock` and reproduced by `Dockerfile`.

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --path:src tests/test_sim.nim          # and every other tests/*.nim
docker build -t coworld-chemistry:ci .
./tools/ci/docker_smoke.sh coworld-chemistry:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

`.github/workflows/ci.yml` runs all three: the Nim tests twice (debug and
release), a real eight-seat episode in raw Docker off the certification
fixture, and the static replay bundle **executed** in headless chromium against
that episode's replay.

Design note: [`docs/plans/2026-08-25-chemistry-design.md`](docs/plans/2026-08-25-chemistry-design.md).
