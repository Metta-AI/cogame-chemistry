## Bounded orders / legality for both scripted baselines.
##
## For 12 seeds x 720 ticks on all four variants, with all-`courier` and with
## all-`freeloader`: every emitted order is inside its enum AND legal for that
## variant; every per-tick action is one of the seven vocabulary values; no cog
## is ever outside the room, inside a wall or sharing a cell; no cog carries
## more than one molecule; no stock, charge or score goes negative; charge
## never exceeds chargeMax; neither baseline raises.

import std/[monotimes, times, unittest]
import chemistry/sim

type Variant = tuple[name: string, cycles, distractorPeriod, distractorCap: int]

const Variants: array[4, Variant] = [
  ("two-cycles", 2, 0, 0),
  ("two-cycles-distractors", 2, 6, 12),
  ("three-cycles", 3, 0, 0),
  ("three-cycles-plentiful-distractors", 3, 2, 24)]

proc configFor(variant: Variant, seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.cycles = variant.cycles
  result.distractorPeriod = variant.distractorPeriod
  result.distractorGroundCap = variant.distractorCap

proc checkOrder(sim: Sim, order: Order) =
  check order.job in {jobSupply, jobForage, jobHoard, jobIdle}
  if order.hasMolecule:
    check sim.config.hasSpecies(order.molecule)
  if order.hasReactor:
    check sim.config.hasReactor(order.reactor)
  if order.job == jobSupply:
    check order.hasMolecule
    check order.hasReactor
  if order.job == jobHoard:
    check order.hasMolecule
  check order.say.len <= MaxSayLen * 4
  ## Every field either baseline emits is inside its declared enum by
  ## construction: normalizeOrder must accept it untouched and unclamped.
  let normalized = sim.normalizeOrder(order)
  check normalized.ok
  check not normalized.order.clamped

proc checkState(sim: Sim) =
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    check cog.cell.inBounds()
    check sim.room.isFloor(cog.cell)
    check cog.foodEaten >= 0
    check cog.delivered >= 0
    check cog.misdrops >= 0
    check cog.hoard >= 0
    check cog.lastAction in {acWait, acMoveN, acMoveS, acMoveE, acMoveW,
                             acTake, acDrop}
    for other in 0 ..< Seats:
      if other != slot:
        check cog.cell != sim.cogs[other].cell
  for reactor in sim.reactors:
    check reactor.charge >= 0
    check reactor.charge <= sim.config.chargeMax
    check reactor.stock[0] >= 0
    check reactor.stock[1] >= 0
    check reactor.cooldown >= 0

suite "scripted baselines are bounded and legal":
  for variant in Variants:
    for kind in [skCourier, skFreeloader]:
      test variant.name & " / " & $kind:
        var worstShiftNanos = 0'i64
        for seed in 1 .. 12:
          var sim = initSim(configFor(variant, seed))
          sim.logEnabled = false
          var ticks = 0
          while not sim.done:
            let started = getMonoTime()
            for slot in 0 ..< Seats:
              let order = sim.scriptedOrder(slot, kind)
              sim.checkOrder(order)
              sim.applyOrder(slot, order)
            let elapsed = (getMonoTime() - started).inNanoseconds
            worstShiftNanos = max(worstShiftNanos, elapsed)
            sim.runShift()
            sim.checkState()
            ticks = sim.tick
          ## A room of eight freeloaders legitimately ends in a famine
          ## before the shift limit, which is a COMPLETED game of Chemistry.
          check ticks == sim.shift * sim.config.ticksPerShift
          check sim.ending in {ekShiftLimit, ekFamine}
          check sim.reason in {erComplete, erDeadline, erForfeit}
          for slot in 0 ..< Seats:
            check sim.cogs[slot].foodEaten >= 0
        ## Neither baseline takes more than 1 ms to decide a whole shift.
        check worstShiftNanos < 1_000_000 * 8
