## Chemistry player: a policy is just a prompt.
##
## Forked from `cogame-bullwhip/src/bullwhip_player.nim` (the thin
## prompt-carrying player process paintbot does not have). Connects to the
## game, delivers its prompt (from PLAYER_PROMPT, or a default shift-foreman
## strategy), then idles until the final frame. ALL decision making happens
## inside the game container, which is what makes one parallel batch of eight
## per shift possible.
##
## PLAYER_SCRIPTED=courier registers the seat as the built-in working baseline
## instead; PLAYER_SCRIPTED=freeloader as the shirker. The server plays those
## deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <chemistry-image> --name my-chemistry \
##     --run /bin/chemistry-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Keep all three vats running. Each shift, read the three charges first: a vat at
charge 0 is a hole in the floor, because restarting it costs three of each
feedstock and makes no food at all. Pick the lane -- vat plus feedstock --
whose stock is lowest on the vat with the lowest charge, and supply it. Say
your lane out loud in the form 'resin to Amber' so the others can cover the
lanes you left, and keep it while nobody else claims it. Never carry glitter or
quartz: they are inert, and dropping one on a vat destroys it and wastes your
whole shift. Only forage when every vat has both stocks at 2 or more, and then
stand on the spill ring of the vat with the highest charge, because that is
where the next food lands. Keep notes of which alias covered which lane.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "chemistry player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "chemistry player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  var running = true
  while running:
    ## whisky's `receiveMessage` RAISES on a close frame or a truncated read
    ## (only a timeout returns none), and mummy's `send` only queues -- the
    ## game's quit(0) can outrun the flushed final frame. Exiting non-zero
    ## there makes hosted certification fail intermittently while
    ## docker_smoke passes (raid, 2026-08-23), so a dead socket is a clean
    ## exit 0.
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "chemistry player: socket closed (", error.msg, "), exiting"
      break
    if received.isNone:
      echo "chemistry player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "chemistry player: seated at slot ", payload{"slot"}.getInt(),
          " as ", payload{"name"}.getStr(), " (",
          payload{"variant"}.getStr(), ")"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "final":
        echo "chemistry player: final scores ", payload{"scores"},
          " reason ", payload{"reason"}.getStr()
        running = false
      else:
        discard
    except CatchableError as error:
      echo "chemistry player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
