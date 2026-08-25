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
## `window.CTF_WIRE` at its line 72 and that file ships BYTE-FOR-BYTE, so
## renaming the global would force a byte change in a file that must not
## change.

import std/strutils
import sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for index, value in values:
    if index > 0: result.add ","
    result.add $value
  result.add "]"

const WireConstantsJs* =
  "window.CTF_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
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
