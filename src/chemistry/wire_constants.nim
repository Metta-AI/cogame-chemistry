## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with (playback speeds, fps, the chrome sprite id).
##
## Forked from `coworld-ctf/src/ctf/wire_constants.nim`. Historically each HTML
## client re-typed these as literals and nothing enforced agreement -- a
## retuned PlaybackSpeeds would silently desync every client. This module
## renders them ONCE, from the same Nim consts the engine runs on;
## `server.nim` splices the block into the served client page and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
##
## **The global keeps its name**: `client/chrome_common.js` reads
## `window.CTF_WIRE` at its line 72 and that file ships byte-pinned (coworld-
## ctf's bytes plus only the fleet-wide 0.5x transport patch), so renaming
## the global would force a further byte change in a pinned file.

import std/strutils
import sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for index, value in values:
    if index > 0: result.add ","
    result.add $value
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.CTF_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.CTF_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")
