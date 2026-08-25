## The chrome frame, and the page's scope hygiene.

import std/[algorithm, json, os, sha1, strutils, unicode, unittest]
import chemistry/sim
import chemistry/broadcast
import chemistry/replays

const RepoRoot = currentSourcePath().parentDir().parentDir()

proc stripJsComments(text: string): string =
  ## Drops HTML comments, // line comments and /* */ blocks, so a scan for
  ## declarations never reads the prose that names the very trap it guards.
  type Mode = enum mCode, mLine, mBlock, mHtml
  var mode = mCode
  var index = 0
  while index < text.len:
    case mode
    of mLine:
      if text[index] == '\n':
        mode = mCode
        result.add text[index]
      inc index
    of mBlock:
      if text.continuesWith("*/", index):
        mode = mCode
        index += 2
      else:
        inc index
    of mHtml:
      if text.continuesWith("-->", index):
        mode = mCode
        index += 3
      else:
        inc index
    of mCode:
      if text.continuesWith("<!--", index):
        mode = mHtml
        index += 4
      elif text.continuesWith("//", index):
        mode = mLine
        index += 2
      elif text.continuesWith("/*", index):
        mode = mBlock
        index += 2
      else:
        result.add text[index]
        inc index

proc playEpisode(cycles = 3, distractorPeriod = 2): Sim =
  var config = defaultGameConfig()
  config.seed = 21
  config.cycles = cycles
  config.distractorPeriod = distractorPeriod
  config.distractorGroundCap = 24
  result = initSim(config)
  result.logEnabled = false
  result.policyNames = @["chemistry-foreman", "chemistry-courier",
    "chemistry-courier", "chemistry-metabolist", "chemistry-courier",
    "chemistry-freeloader", "chemistry-courier", "chemistry-freeloader"]
  let bigSay = "\u00e9\u2014".repeat(90)
  while not result.done:
    for slot in 0 ..< Seats:
      var order = result.courierOrder(slot)
      order.say = sayText(bigSay)
      result.applyOrder(slot, order)
    result.runShift()

proc chromeFor(sim: Sim, tick: int, phase: string): JsonNode =
  var index = 0
  for i, frame in sim.frames:
    if frame.tick <= tick: index = i
  var input = ChromeInput(
    config: sim.config,
    frame: sim.frames[index],
    tick: sim.frames[index].tick,
    maxTick: sim.tick,
    startTick: 0,
    shift: sim.shift,
    phase: phase,
    playing: true,
    looping: true,
    transportEnabled: true,
    speed: 1,
    events: sim.events.eventsJson(),
    beats: sim.beatsJson(),
    results: sim.resultsJson())
  for slot in 0 ..< Seats:
    input.names.add sim.cogs[slot].alias
    input.policyNames.add sim.policyNames[slot]
    input.colors.add sim.cogs[slot].color
  var tracker = initBroadcastTracker(sim.reactors.len)
  tracker.rebuild(sim.config, sim.events.eventsJson(), input.tick)
  input.tracker = tracker
  var player = initReplayPlayer(parseReplayBytes(
    buildReplay(sim, sim.resultsJson())))
  input.lead = player.leadSeries()
  parseJson(buildStateJson(input))

suite "chrome frame":
  let sim = playEpisode()

  test "teams are exactly the present cycles, each headlined by its own name":
    let state = chromeFor(sim, 300, "playing")
    var keys: seq[string]
    for key, value in state{"teams"}:
      keys.add key
    check keys.sorted() == @["amber", "beryl", "cobalt"]
    for key, entry in state{"teams"}:
      check entry{"policies"}.len == 1
      check entry{"policies"}[0].getStr().toLowerAscii() == key
      check entry{"lives"}.getInt() == entry{"charge"}.getInt()
      check entry{"chargeMax"}.getInt() == sim.config.chargeMax
      check entry{"status"}.getStr() in ["RUNNING", "STARVING", "COLD"]
      check entry{"stock"}.len == 2
      check entry{"feed"}.len == 2

  test "two cycles produce two plates":
    let two = playEpisode(2, 0)
    let state = chromeFor(two, 200, "playing")
    check state{"teams"}.len == 2
    check state{"teams"}.hasKey("amber")
    check state{"teams"}.hasKey("beryl")
    check not state{"teams"}.hasKey("cobalt")

  test "the roster carries the alias in name and the POLICY in pol":
    let state = chromeFor(sim, 300, "playing")
    check state{"roster"}.len == Seats
    for index in 0 ..< Seats:
      let seat = state{"roster"}[index]
      check seat{"s"}.getInt() == index
      check seat{"name"}.getStr() == SeatAliases[index]
      check seat{"pol"}.getStr() == sim.policyNames[index]
      check seat{"col"}.getStr() == SeatColors[index]
      check seat{"ate"}.getInt() >= 0
      check seat{"hd"}.getInt() >= 0
      check seat{"say"}.getStr().runeLen <= MaxSayLen

  test "lead is the shape chrome_common.js expects: {teams, pts:[[t, ...]]}":
    let state = chromeFor(sim, 300, "playing")
    let lead = state{"lead"}
    check lead{"teams"}.len == sim.reactors.len
    check lead{"pts"}.len > 2
    for point in lead{"pts"}:
      check point.len == sim.reactors.len + 1

  test "beats carry only the five declared kinds":
    let state = chromeFor(sim, 300, "playing")
    for beat in state{"beats"}:
      check beat{"k"}.getStr() in
        ["shift", "cold", "restart", "famine", "gameover"]

  test "the terminal frame carries `over` with the ending string":
    let state = chromeFor(sim, sim.tick, "gameover")
    check state.hasKey("over")
    check state{"over"}{"ending"}.getStr() in
      ["shift_limit", "famine", "deadline", "forfeit"]
    check state{"over"}{"scores"}.len == Seats
    check state{"over"}{"winner"}.getStr().len > 0
    check state{"over"}{"winnerPolicy"}.getStr().len > 0

  test "every feed string is inside its cap":
    let state = chromeFor(sim, sim.tick, "gameover")
    for event in state{"events"}:
      if event{"k"}.getStr() == "order":
        check event{"say"}.getStr().runeLen <= MaxSayLen
        check event{"notes"}.getStr().runeLen <= MaxNotesLen

suite "the broadcast page":
  let page = readFile(RepoRoot / "client" / "replay_broadcast.html")
  let banner = "CHEMISTRY additions to the inherited coworld-ctf chrome"
  ## The game block starts at the `<!--` that opens its banner, so a comment
  ## stripper run over it starts in code, not mid-comment.
  let split = page.rfind("<!--", 0, page.find(banner))

  test "the game block is APPENDED under its banner, not a rewrite":
    check banner in page
    check split > 0
    let inherited = page[0 ..< split]
    let gameBlock = page[split .. ^1]
    ## The starter's own chrome is still there.
    for id in ["id=\"stage\"", "id=\"board\"", "id=\"chrome\"",
               "id=\"scorebug\"", "id=\"plates-l\"", "id=\"plates-r\"",
               "id=\"clock\"", "id=\"clock-time\"", "id=\"clock-caption\"",
               "id=\"bannerlane\"", "id=\"killfeed\"", "id=\"transport\"",
               "id=\"btn-restart\"", "id=\"btn-back\"", "id=\"btn-play\"",
               "id=\"btn-fwd\"", "id=\"btn-end\"", "id=\"btn-loop\"",
               "id=\"btn-skip\"", "id=\"btn-spoilers\"", "id=\"scrub\"",
               "id=\"momentum\"", "id=\"scrub-fill\"", "id=\"lulls\"",
               "id=\"scrub-win\"", "id=\"scrub-head\"", "id=\"endcard\"",
               "id=\"status\"", "id=\"lockerroom\""]:
      check id in inherited
    check gameBlock.len > 4000

  test "only the listed elements were removed":
    for id in ["\"viewpanel\"", "\"minimap\"", "\"minimap-canvas\"",
               "\"zoombar\"", "\"zoom-out\"", "\"zoom-slider\"",
               "\"zoom-in\"", "\"zoom-read\"", "\"fpv\"", "\"fpv-canvas\"",
               "\"fpv-hud\"", "\"fpv-name\"", "\"fpv-hp\"", "\"fpv-gear\"",
               "\"fpv-map\"", "\"fpv-map-canvas\"", "\"fpv-cap\"",
               "\"fpv-grip\"", "\"povBadge\"", "\"mmwarn\""]:
      check ("id=" & id) notin page
      check ("$(" & id & ")") notin page

  test "the two re-lettered literals, and the locker-room click fix":
    check "CYCLE CHARGE" in page
    check "LIVES LEAD" notin page
    check ">Charge<" in page
    check ">Lives<" notin page
    check "#lockerroom { pointer-events: none; }" in page

  test "transport rules: bands on :root, endcard above the band, seeks dismiss it":
    check "root.style.setProperty('--hudscale'" in page
    check "root.style.setProperty('--band'" in page
    check "root.style.setProperty('--topband'" in page
    check "bottom: var(--band, 0px);" in page
    ## Nothing the game block adds may sit inside the transport band.
    check "#killfeed { bottom: calc(var(--band, 0px)" in page
    check "$('endcard').classList.remove('on');" in page

  test "the scrubber has CSS for every beat kind the game emits":
    for kind in ["shift", "cold", "restart", "famine", "gameover"]:
      check (".beat-marker." & kind & " {") in page
    check ".beat-marker.chem {" in page

  test "?spoilers=0 holds the game block's beats back until the playhead":
    ## The markers are the game block's own buttons, so they are not in
    ## chrome_common's `markerEls` and its gate cannot see them: the block
    ## runs the same rule itself, off the chrome's own spoiler flag.
    let gameBlock = page[split .. ^1].stripJsComments()
    check "getSpoilers" in page[0 ..< split]
    check "C.getSpoilers" in gameBlock
    check "el.__tick > s.t" in gameBlock
    check "applyChemBeatSpoilers(s)" in gameBlock

  test ".plate-name takes the slack and labels hide under 640px":
    check ".plate-name, .plate .team-name { flex: 1 1 auto; min-width: 3.2em; }" in page
    check "@media (max-width: 640px) {" in page
    check "#roster .chip .pol { display: none; }" in page

  test "the beat builder is buildChemBeats, never markBeat (the hoist trap)":
    let gameBlock = page[split .. ^1].stripJsComments()
    check "function buildChemBeats(" in gameBlock
    check "function markBeat" notin gameBlock

  test "the game block is its own IIFE, so nothing in it can hoist into the chrome":
    let gameBlock = page[split .. ^1]
    check "(function () {" in gameBlock
    check "window.CHEM" in gameBlock
    ## The chrome closure ends BEFORE the banner.
    check page[0 ..< split].count("})();") >= 1

  test "scope duplication: no game-block name collides with the chrome aliases":
    ## A game-block `function markBeat` hoists over the chrome alias block's
    ## `var markBeat = C.markBeat` and silently kills every scrubber beat
    ## (tandem, 2026-08-23). Collect BOTH lists from the file and diff them.
    let inherited = page[0 ..< split]
    let gameBlock = page[split .. ^1]
    var aliases: seq[string]
    for line in inherited.splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("var ") or " = C." notin trimmed:
        continue
      for part in trimmed[4 .. ^1].split(','):
        let pieces = part.split('=')
        if pieces.len == 2 and ".C." notin pieces[1] and
            pieces[1].strip().startsWith("C."):
          aliases.add pieces[0].strip()
    check aliases.len >= 15
    check "markBeat" in aliases
    ## Every FUNCTION DECLARATION the game block makes -- those are what
    ## hoist. Hand-scanned rather than regexed so the test needs no libpcre,
    ## and over a comment-stripped copy so the prose that names the trap does
    ## not trip the check.
    proc identifierAt(text: string, start: int): string =
      var index = start
      while index < text.len and text[index] in
          {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '$'}:
        result.add text[index]
        inc index
    let clean = gameBlock.stripJsComments()
    var declared: seq[string]
    var cursor = 0
    while true:
      let hit = clean.find("function ", cursor)
      if hit < 0:
        break
      cursor = hit + "function ".len
      if hit > 0 and clean[hit - 1] in
          {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '$', '.'}:
        continue
      var index = cursor
      while index < clean.len and clean[index] == ' ':
        inc index
      let name = clean.identifierAt(index)
      if name.len > 0:
        declared.add name
    check declared.len > 5
    for name in declared:
      check name notin aliases

suite "viewer provenance":
  test "chrome_common.js is coworld-ctf's file, byte for byte":
    ## The design note pins this: nothing in it is edited, which is why the
    ## wire-constants global keeps the name `window.CTF_WIRE` and why the
    ## cycle plates ride the starter's own teams / roster machinery. The
    ## Digest of `Metta-AI/coworld-ctf@bfd5e9c client/chrome_common.js`
    ## (sha256 7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c).
    let bytes = readFile(RepoRoot / "client" / "chrome_common.js")
    check $secureHash(bytes) ==
      "D970EBE4EFF1B0154BA604B4E9ADF62D601CB3EB"
    check "window.CTF_WIRE" in bytes

  test "all four viewer files came from coworld-ctf and were renamed together":
    ## Never splice one starter's shell onto another's link flags: paintbot's
    ## shell waits for Module.onRuntimeInitialized and its config.nims has NO
    ## MODULARIZE / EXPORT_NAME. Keep that matched pair (cogame-lantern,
    ## 2026-08-23).
    let config = readFile(RepoRoot / "replay-viewer" / "config.nims")
    let worker = readFile(RepoRoot / "replay-viewer" /
      "static_replay_worker.js")
    let shell = readFile(RepoRoot / "replay-viewer" / "static_replay.js")
    let entry = readFile(RepoRoot / "replay-viewer" / "chemistry_replay.nim")
    check "MODULARIZE" notin config
    check "EXPORT_NAME" notin config
    check "Module.onRuntimeInitialized" in worker
    check "-s ABORTING_MALLOC=1" in config
    check "-s ALLOW_MEMORY_GROWTH" in config
    check "-s FILESYSTEM=1" in config
    check "-s ENVIRONMENT=web,worker,node" in config
    check "-s EXPORTED_RUNTIME_METHODS=HEAPU8" in config
    check "--preload-file" in config
    check "-d:useMalloc" in config
    for name in ["_chemistry_load_replay", "_chemistry_frame",
                 "_chemistry_input", "_chemistry_packet_ptr",
                 "_chemistry_packet_len", "_chemistry_error_ptr",
                 "_chemistry_error_len", "_chemistry_stage_ptr",
                 "_chemistry_stage_len"]:
      check name in config
    ## There is no re-simulation, so there is no mismatch tick to report.
    check "mismatch" notin config
    check "mismatch" notin worker
    check "mismatch" notin shell
    check "ctf_" notin worker
    check "emscripten_exit_with_live_runtime" in entry
    check "'./chemistry_replay.js'" in worker

  test "the shell reports through both signals the CI gate reads":
    let shell = readFile(RepoRoot / "replay-viewer" / "static_replay.js")
    check "'data-replay-loaded', 'true'" in shell
    check "'data-replay-error'" in shell
