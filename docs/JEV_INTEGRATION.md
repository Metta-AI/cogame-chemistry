# Jev as a Chemistry player

`chemistry.player.v2` gives an external player the acting seat's ordinary
observation and exact legal standing-order menu for each simultaneous shift.
The player replies with a decision ID and offered order ID. The game checks
both, applies the courier kernel, and owns results and replay. Prompt and
courier/freeloader scripted players remain on the same image.

`PLAYER_JEV=1` ranks the complete legal menu through SystemOne in the player
container. Direct `TYPESAFE_API_KEY` and the hosted inference sidecar are
player credentials. `PLAYER_PROMPT` can add policy guidance. The menu contains
at most 25 order IDs across current variants, within SystemOne's 255-choice
limit. Supply orders include off-graph combinations because the game's rules
allow a misdrop.

## Local evidence

The `linux/amd64` image completed the normal eight-seat Docker smoke. The
mixed mock SystemOne smoke covered two cycles, three cycles with distractors,
and two Jev seats in one simultaneous three-cycle episode. It accepted 12 Jev
orders with no scripted fallback and checked private observations, legal
menus, direct and sidecar headers, results, and replayed orders. These mock
decisions verify interface wiring, not Jev quality or provider cost. All seven
native suites passed in Linux debug and release builds. A release-pinned
`coworld[auth]==0.1.43` build of `compose.jev-local.yaml` certified the normal
roster with all ten transcript checks. The static viewer loaded the two-Jev
replay at `http://127.0.0.1:39816/?replay=replay.json`; pausing and selecting
shift 2 displayed tick 120 of 180. No hosted resource changed.
