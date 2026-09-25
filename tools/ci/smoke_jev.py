"""Run Jev beside courier players across Chemistry variants."""

import json
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class MockSystemOne(BaseHTTPRequestHandler):
    choices: list[tuple[int, str]] = []
    direct = False

    def do_POST(self) -> None:
        assert self.path == "/v1/systemone"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        observation = json.loads(request["state"].split("Your observation:\n", 1)[1])
        assert "policyNames" not in observation
        assert "seed" not in observation
        assert len(observation["cogs"]) == 8
        assert all("notes" not in seat for seat in observation["cogs"])
        assert "notes" in observation and "carrying" in observation["you"]
        legal = observation["legalOrders"]
        ids = {option["id"] for option in legal}
        assert 0 < len(legal) <= 255 and "idle" in ids
        assert len(legal) == 2 + len(observation["reactors"]) + len(
            observation["molecules"]) * (1 + len(observation["reactors"]))
        assert "supply:resin:amber" in ids
        criteria = request["questions"]["order"]["criteria"]
        assert set(criteria) == ids
        choice = "supply:resin:amber"
        assert choice in criteria
        self.choices.append((observation["slot"], choice))
        if self.direct:
            assert self.headers.get("authorization") == "Bearer mock"
            assert self.headers.get("x-coworld-player-slot") is None
        else:
            assert self.headers.get("authorization") is None
            assert self.headers.get("x-coworld-player-slot") == str(observation["slot"])
        data = json.dumps({
            "model": "mock-jev",
            "answers": {"order": {
                "type": "choice", "confidence": 1.0,
                "probabilities": {name: float(name == choice) for name in criteria},
            }},
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:
        pass


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def main() -> None:
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    image = sys.argv[2] if len(sys.argv) > 2 else "chemistry-jev-25001:local"
    variants = json.loads(Path("coworld_manifest_template.json").read_text())["variants"]
    cases = [(variants[0], [0], "two-cycles"),
             (variants[3], [1], "three-cycles-distractors"),
             (variants[3], [0, 1], "three-cycles-two-jev")]
    mock = ThreadingHTTPServer(("0.0.0.0", 0), MockSystemOne)
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    try:
        for index, (variant, jev_slots, name) in enumerate(cases):
            MockSystemOne.choices = []
            MockSystemOne.direct = index == 0
            episode = output / name
            episode.mkdir(exist_ok=True)
            config = dict(variant["game_config"])
            config.update({
                "players": [{"name": f"Jev {slot}" if slot in jev_slots else f"Courier {slot}"}
                            for slot in range(8)],
                "tokens": [f"chem-{slot}" for slot in range(8)],
                "seed": 7, "shifts": 3, "minTurnSeconds": 0,
                "llmTimeoutSeconds": 20, "shutdownGraceSeconds": 1,
                "playerConnectTimeoutSeconds": 60,
            })
            (episode / "config.json").write_text(json.dumps(config))
            port = free_port()
            game_name = f"chemistry-jev-smoke-{name}"
            game_log = (episode / "game.log").open("w")
            game = subprocess.Popen([
                "docker", "run", "--rm", "--platform=linux/amd64",
                "--add-host=host.docker.internal:host-gateway",
                "--name", game_name, "-p", f"{port}:8080",
                "-v", f"{episode}:/coworld", "-e", "COGAME_HOST=0.0.0.0",
                "-e", "COGAME_PORT=8080",
                "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
                "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
                "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
                image, "/bin/chemistry",
            ], stdout=game_log, stderr=subprocess.STDOUT)
            players = []
            try:
                ready = False
                for _ in range(150):
                    if game.poll() is not None:
                        break
                    ready = subprocess.run([
                        "curl", "-fsS", "--max-time", "1",
                        f"http://127.0.0.1:{port}/healthz",
                    ], stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL).returncode == 0
                    if ready:
                        break
                    time.sleep(0.1)
                assert ready and game.poll() is None, (episode / "game.log").read_text()
                for slot in range(8):
                    env = ["-e", f"COWORLD_PLAYER_WS_URL=ws://host.docker.internal:{port}/player?slot={slot}&token=chem-{slot}"]
                    if slot in jev_slots:
                        env += ["-e", "PLAYER_JEV=1"]
                        if MockSystemOne.direct:
                            env += ["-e", f"METTA_CAPTURE_URL=http://host.docker.internal:{mock.server_port}",
                                    "-e", "METTA_CAPTURE_KEY=mock"]
                        else:
                            env += ["-e", f"AWS_ENDPOINT_URL_BEDROCK_RUNTIME=http://host.docker.internal:{mock.server_port}"]
                    else:
                        env += ["-e", "PLAYER_SCRIPTED=courier"]
                    log = (episode / f"player-{slot}.log").open("w")
                    player = subprocess.Popen([
                        "docker", "run", "--rm", "--platform=linux/amd64",
                        "--add-host=host.docker.internal:host-gateway",
                        *env, image, "/bin/chemistry-player",
                    ], stdout=log, stderr=subprocess.STDOUT)
                    players.append((player, log))
                for _ in range(1200):
                    if (episode / "results.json").exists() and (episode / "replay.json").exists():
                        break
                    if game.poll() is not None:
                        break
                    time.sleep(0.1)
                assert (episode / "results.json").exists(), (episode / "game.log").read_text()
                assert (episode / "replay.json").exists(), (episode / "game.log").read_text()
                for player, _ in players:
                    assert player.wait(timeout=10) == 0
                results = json.loads((episode / "results.json").read_text())
                replay = json.loads((episode / "replay.json").read_text())
                events = [e for e in replay["events"]
                          if e["k"] == "order" and e["seat"] in jev_slots]
                assert len(events) == len(MockSystemOne.choices) == 3 * len(jev_slots)
                for slot in jev_slots:
                    seat_events = [e for e in events if e["seat"] == slot]
                    seat_choices = [choice for source, choice in MockSystemOne.choices
                                    if source == slot]
                    assert len(seat_events) == len(seat_choices) == 3
                    for event, choice in zip(seat_events, seat_choices, strict=True):
                        assert choice == "supply:resin:amber"
                        assert event["job"] == "supply"
                        assert event["sp"] == "resin" and event["rx"] == "amber"
                        assert event["source"] == "external" and not event["clamped"]
                assert results["shifts"] == 3 and len(results["scores"]) == 8
                print(f"{name}: {len(events)} accepted Jev actions, 0 scripted fallback")
            finally:
                subprocess.run(["docker", "stop", "--time", "1", game_name],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for player, log in players:
                    if player.poll() is None:
                        player.terminate()
                        player.wait(timeout=5)
                    log.close()
                game_log.close()
    finally:
        mock.shutdown()
        mock.server_close()


if __name__ == "__main__":
    main()
