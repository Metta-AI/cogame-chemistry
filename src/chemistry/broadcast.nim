## The broadcast chrome frame.
##
## Forked from `coworld-ctf/src/ctf/broadcast.nim`: `BroadcastTracker` +
## `buildStateJson` keep their shape, `teams` becomes the three cycles,
## `roster` the eight cogs and `lead` the charge series. The binary sprite
## stream stays the board renderer; this module produces the parallel
## TextMessage the broadcast client reads for the scorebug, the feed, the
## roster strip, the shame panel, the transport and the end card.

import std/[json, strutils]
import sim_types, sim_config, sim_state

type
  BroadcastTracker* = object
    ## Per-viewer cumulative seat counters, derived by replaying the recorded
    ## events up to the playhead. Chemistry records state, not inputs, so a
    ## seek re-derives these from scratch -- 500 rows, free.
    upto*: int
    eaten*: array[MaxSeats, int]
    delivered*: array[MaxSeats, int]
    misdrops*: array[MaxSeats, int]
    hoard*: array[MaxSeats, int]
    says*: array[MaxSeats, string]
    jobs*: array[MaxSeats, string]
    lastReaction*: seq[int]

  ChromeInput* = object
    config*: GameConfig
    names*: seq[string]
    policyNames*: seq[string]
    colors*: seq[string]
    frame*: Frame
    tick*: int
    maxTick*: int
    startTick*: int
    shift*: int
    phase*: string
    tracker*: BroadcastTracker
    playing*: bool
    looping*: bool
    skipLulls*: bool
    fastForwarding*: bool
    transportEnabled*: bool
    speed*: float
    events*: JsonNode
    beats*: JsonNode
    lead*: JsonNode
    results*: JsonNode
    holdSeconds*: int

proc initBroadcastTracker*(reactors: int): BroadcastTracker =
  result.upto = -1
  result.lastReaction = newSeq[int](reactors)
  for index in 0 ..< reactors:
    result.lastReaction[index] = -10_000

proc reactorIndexOf(config: GameConfig, name: string): int =
  for index, present in config.reactorsPresent():
    if $present == name:
      return index
  -1

proc rebuild*(
  tracker: var BroadcastTracker,
  config: GameConfig,
  events: JsonNode,
  upto: int
) =
  ## Re-derives every cumulative counter from the event log up to `upto`.
  ## Called on the first frame and after any seek; a forward step re-runs it
  ## too, because 500 rows is cheaper than keeping two code paths honest.
  tracker = initBroadcastTracker(config.reactorsPresent().len)
  tracker.upto = upto
  for event in events:
    let tick = event{"t"}.getInt(-1)
    if tick > upto:
      break
    case event{"k"}.getStr()
    of "eat":
      let seat = event{"seat"}.getInt(-1)
      if seat >= 0 and seat < MaxSeats: tracker.eaten[seat].inc
    of "drop":
      let seat = event{"seat"}.getInt(-1)
      if seat >= 0 and seat < MaxSeats:
        if event{"rx"}.getStr().len > 0: tracker.delivered[seat].inc
    of "misdrop":
      let seat = event{"seat"}.getInt(-1)
      if seat >= 0 and seat < MaxSeats: tracker.misdrops[seat].inc
    of "order":
      let seat = event{"seat"}.getInt(-1)
      if seat >= 0 and seat < MaxSeats:
        tracker.says[seat] = event{"say"}.getStr()
        var job = event{"job"}.getStr()
        if event{"sp"}.getStr().len > 0: job.add " " & event{"sp"}.getStr()
        if event{"rx"}.getStr().len > 0: job.add " \u2192 " & event{"rx"}.getStr()
        tracker.jobs[seat] = job
    of "react", "restart":
      let index = config.reactorIndexOf(event{"rx"}.getStr())
      if index >= 0 and index < tracker.lastReaction.len:
        tracker.lastReaction[index] = tick
    else:
      discard
  ## Hoarding is counted from the drops that landed on a seat's own home.
  for event in events:
    let tick = event{"t"}.getInt(-1)
    if tick > upto:
      break
    if event{"k"}.getStr() != "drop" or event{"rx"}.getStr().len > 0:
      continue
    let seat = event{"seat"}.getInt(-1)
    if seat < 0 or seat >= MaxSeats:
      continue
    if event{"x"}.getInt(-1) == SeatHomes[seat].x and
        event{"y"}.getInt(-1) == SeatHomes[seat].y:
      tracker.hoard[seat].inc

proc statusWord*(charge, ticksSinceReaction, stockA, stockB: int): string =
  ## The viewer's copy of `reactorStatus`: STARVING covers an empty stock as
  ## well as a stalled cycle, so the scorebug word and the observation agree.
  if charge <= 0: "COLD"
  elif stockA <= 0 or stockB <= 0: "STARVING"
  elif ticksSinceReaction <= 48: "RUNNING"
  else: "STARVING"

proc titleCase(text: string): string =
  if text.len == 0: text else: text[0..0].toUpperAscii() & text[1 .. ^1]

proc buildStateJson*(input: ChromeInput): string =
  ## The broadcast chrome frame. Board-derived STATE (charges, roster, the end
  ## card) is always present, so a frame reached by a seek still hydrates the
  ## scorebug with no events at all.
  let reactors = input.config.reactorsPresent()
  var teams = newJObject()
  for index, name in reactors:
    let base = index * 4
    let charge =
      if base < input.frame.reactors.len: input.frame.reactors[base] else: 0
    let stockA =
      if base + 1 < input.frame.reactors.len: input.frame.reactors[base + 1]
      else: 0
    let stockB =
      if base + 2 < input.frame.reactors.len: input.frame.reactors[base + 2]
      else: 0
    let since =
      if index < input.tracker.lastReaction.len:
        input.tick - input.tracker.lastReaction[index]
      else: 10_000
    var policies = newJArray()
    policies.add(%titleCase($name))
    ## `lives` is the starter's plate numeral, re-lettered `Charge` in the
    ## page: the big number IS the reactor's charge.
    teams[$name] = %*{
      "lives": charge,
      "policies": policies,
      "charge": charge,
      "chargeMax": input.config.chargeMax,
      "status": statusWord(charge, since, stockA, stockB),
      "stock": [stockA, stockB],
      "feed": [$ReactorFeed[name][0], $ReactorFeed[name][1]],
      "cold": input.config.coldStartCost,
      "yieldNow": 1 + min(input.config.chargeMax, charge + 1) div 3
    }

  var roster = newJArray()
  for slot in 0 ..< Seats:
    let base = slot * 4
    let x = if base < input.frame.cogs.len: input.frame.cogs[base] else: 0
    let y = if base + 1 < input.frame.cogs.len: input.frame.cogs[base + 1]
            else: 0
    let carry = if base + 2 < input.frame.cogs.len: input.frame.cogs[base + 2]
                else: -1
    let ate = if base + 3 < input.frame.cogs.len: input.frame.cogs[base + 3]
              else: 0
    roster.add(%*{
      "s": slot,
      "name": (if slot < input.names.len: input.names[slot]
               else: SeatAliases[slot]),
      "pol": (if slot < input.policyNames.len: input.policyNames[slot]
              else: SeatAliases[slot]),
      "col": (if slot < input.colors.len: input.colors[slot]
              else: SeatColors[slot]),
      "cell": [x, y],
      "carry": (if carry >= 0: %($speciesFromId(carry)) else: newJNull()),
      "ate": ate,
      "dl": input.tracker.delivered[slot],
      "md": input.tracker.misdrops[slot],
      "hd": input.tracker.hoard[slot],
      "job": input.tracker.jobs[slot],
      "say": input.tracker.says[slot],
      "alive": true,
      "lives": 0
    })

  var state = %*{
    "t": input.tick,
    "mt": input.maxTick,
    "ph": input.phase,
    "lob": 0,
    "pl": input.playing,
    "sp": input.speed,
    "mx": input.maxTick,
    "st": input.startTick,
    "lp": input.looping,
    "sk": input.skipLulls,
    "ff": input.fastForwarding,
    "en": input.transportEnabled,
    "mm": -1,
    "bs": 1,
    "pov": -1,
    "shift": input.shift,
    "shifts": input.config.shifts,
    "tps": input.config.ticksPerShift,
    "variant": input.config.variantId(),
    "dist": input.config.distractorPeriod,
    "teams": teams,
    "roster": roster,
    "events": (if input.events.isNil: newJArray() else: input.events)
  }
  if not input.lead.isNil and input.lead.kind == JObject:
    state["lead"] = input.lead
  if not input.beats.isNil and input.beats.len > 0:
    state["beats"] = input.beats
  if input.phase == "gameover" and not input.results.isNil and
      input.results.kind == JObject:
    var scores = newJArray()
    for value in input.results{"scores"}:
      scores.add value
    var winner = ""
    var winnerPolicy = ""
    var best = -1
    for slot in 0 ..< Seats:
      let score = input.results{"scores"}[slot].getInt()
      if score > best:
        best = score
        winner = (if slot < input.names.len: input.names[slot]
                  else: SeatAliases[slot])
        winnerPolicy = (if slot < input.policyNames.len:
          input.policyNames[slot] else: winner)
    state["over"] = %*{
      "winner": winner,
      "winnerPolicy": winnerPolicy,
      "draw": false,
      "ending": input.results{"ending"}.getStr("shift_limit"),
      "reason": input.results{"reason"}.getStr("complete"),
      "scores": scores,
      "foodMade": input.results{"food_made"}.getInt(),
      "foodRotted": input.results{"food_rotted"}.getInt(),
      "coldStarts": input.results{"cold_starts"}.getInt()
    }
    if input.holdSeconds > 0:
      state["hold"] = %input.holdSeconds
  $state
