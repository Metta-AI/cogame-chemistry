"""Complete real socket games with external-action seats; records prove prompt intent only."""

import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import sys

import websockets


async def play(binary, folder, configuration, revision, native_failure):
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = configuration | {"tokens": [str(seat) for seat in range(8)]}
    (folder / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
    ):
        environment.pop(key, None)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(folder / "config.json").as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "prompts.jsonl").as_uri(),
        COWORLD_SOURCE_REVISION=revision,
    )
    if native_failure:
        environment["COWORLD_LLM_ENDPOINT"] = "http://127.0.0.1:9/"
    received = {}
    with (folder / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(
            binary, env=environment, stdout=log, stderr=log
        )
        players = []
        try:
            async with asyncio.timeout(20):
                while "serving on" not in (folder / "game.log").read_text():
                    assert process.returncode is None, (folder / "game.log").read_text()
                    await asyncio.sleep(0.02)

            async def player(seat):
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}"
                ) as connection:
                    async for raw in connection:
                        frame = json.loads(raw)
                        if frame["type"] == "welcome":
                            assert frame["protocol"] == "chemistry.player.v2"
                            await connection.send(
                                json.dumps(
                                    {"type": "prompt", "prompt": ""}
                                    if native_failure
                                    else {"type": "register", "control": "external"}
                                )
                            )
                        elif frame["type"] == "observation":
                            observation = frame["observation"]
                            metadata = observation["prompt_template"]
                            messages = frame["messages"]
                            for other in range(8):
                                if other != seat:
                                    assert (
                                        f"PRIVATE-NOTES-{other}"
                                        not in messages[1]["content"]
                                    )
                            lanes = [
                                (reactor["name"], feed)
                                for reactor in observation["reactors"]
                                for feed in reactor["feedstocks"]
                            ]
                            reactor, molecule = lanes[seat % len(lanes)]
                            action = f"supply:{molecule}:{reactor}"
                            assert action in {
                                order["id"] for order in observation["legalOrders"]
                            }
                            received[observation["shift"] - 1, seat] = (
                                messages,
                                metadata,
                            )
                            await connection.send(
                                json.dumps(
                                    {
                                        "type": "action",
                                        "id": frame["id"],
                                        "orderId": action,
                                        "say": f"lane {seat}",
                                        "notes": f"PRIVATE-NOTES-{seat}",
                                    }
                                )
                            )
                        elif frame["type"] == "final":
                            assert frame["done"] and frame["reason"] == "complete"
                            return
                        else:
                            assert frame["type"] == "state"
                    raise AssertionError("socket closed before final results")

            players = [asyncio.create_task(player(seat)) for seat in range(8)]
            async with asyncio.timeout(60):
                await asyncio.gather(*players)
                while "artifacts written" not in (folder / "game.log").read_text():
                    assert process.returncode is None
                    await asyncio.sleep(0.02)
            # All artifacts are complete. Skip the unchanged 20-second shutdown grace.
        finally:
            for task in players:
                task.cancel()
            await asyncio.gather(*players, return_exceptions=True)
            if process.returncode is None:
                process.terminate()
            await process.wait()
    events = [
        json.loads(line) for line in (folder / "prompts.jsonl").read_text().splitlines()
    ]
    summary = events.pop()
    assert summary["kind"] == "episode" and summary["reason"] == "complete"
    assert summary["source_revision"] == revision
    assert (
        len(events)
        == summary["records"]
        == config["shifts"] * 8 * (3 if native_failure else 1)
    )
    systems, users, requests = {}, {}, {}
    for event in events:
        assert event["schema"] == "chemistry.prompt-provenance.v1"
        assert event["kind"] == "prompt"
        metadata = event["prompt_template"]
        assert metadata["bank"] == summary["prompt_bank"] == "chemistry-rules-v1"
        assert metadata["variant"] == summary["prompt_variant"]
        assert metadata["selection"] == config["promptVariant"]
        assert metadata["seed"] == summary["prompt_seed"] == config["promptSeed"]
        assert [message["role"] for message in event["messages"]] == ["system", "user"]
        for message in event["messages"]:
            assert (
                metadata[message["role"] + "_sha256"].lower()
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
        system, user = [message["content"] for message in event["messages"]]
        assert systems.setdefault(event["seat"], system) == system
        key = event["shift"], event["seat"]
        if event["scope"] == "request":
            assert native_failure and event["attempt"] in (0, 1)
            attempt_key = key, event["attempt"]
            assert attempt_key not in requests
            requests[attempt_key] = user
        else:
            assert event["scope"] == "configured_prompt" and event["attempt"] == 0
            if not native_failure:
                assert (event["messages"], metadata) == received[key]
            assert key not in users
            users[key] = user
    if native_failure:
        assert not received
        assert set(requests) == {(key, attempt) for key in users for attempt in (0, 1)}
        for key, user in users.items():
            assert requests[key, 0] == user
            assert requests[key, 1].startswith(user)
            assert "Your previous reply was invalid" in requests[key, 1][len(user) :]
    else:
        assert set(users) == set(received)
    assert set(users) == {
        (turn, seat) for turn in range(config["shifts"]) for seat in range(8)
    }
    result = json.loads((folder / "results.json").read_text())
    assert result["reason"] == "complete" and result["scores"] == summary["scores"]
    public = (folder / "replay.json").read_text() + json.dumps(result)
    assert "prompt_template" not in public and "system_sha256" not in public
    return users, result, systems, summary["prompt_variant"]


async def main():
    binary, destination, revision = sys.argv[1:4]
    assert len(sys.argv) in (4, 5)
    native_failure = len(sys.argv) == 5
    if native_failure:
        assert sys.argv[4] == "--native-failure"
    root = Path(destination).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads(
        (
            Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
        ).read_text()
    )
    templates = [
        "canonical",
        "plain",
        "numbered",
        "questions",
        "reordered",
        "heldout-briefing",
        "heldout-reference",
    ]
    if native_failure:
        templates = ["canonical", "plain", "heldout-briefing"]
    selections = [(name, 0) for name in templates]
    if not native_failure:
        selections.extend(("mixed", i) for i in range(5))
    reports = []
    for variant in manifest["variants"]:
        for seed in (17,) if native_failure else (17, 946001):
            direct = []
            for selection, prompt_seed in selections:
                name = f"{variant['id']}-{seed}-{selection}-{prompt_seed}"
                run = await play(
                    binary,
                    root / name,
                    variant["game_config"]
                    | {
                        "seed": seed,
                        "minTurnSeconds": 0,
                        "promptVariant": selection,
                        "promptSeed": prompt_seed,
                    },
                    revision,
                    native_failure,
                )
                if direct:
                    assert run[:2] == direct[0][:2], (
                        "Wording changed visible state or final scores"
                    )
                if selection == "mixed":
                    assert run[2:] == direct[prompt_seed][2:]
                else:
                    assert run[3] == selection
                    direct.append(run)
                reports.append(
                    {"game": name, "decisions": len(run[0]), "selected": run[3]}
                )
            for seat in range(8):
                assert len({run[2][seat] for run in direct}) == len(templates)
    (root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(
        json.dumps(
            {
                "completed_games": len(reports),
                "templates": len(templates),
                "output": str(root),
            }
        )
    )


asyncio.run(main())
