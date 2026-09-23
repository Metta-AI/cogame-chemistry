"""Exercise all certified Chemistry variants through Metta's numeric protocol."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
VARIANTS = (
    "two-cycles",
    "two-cycles-distractors",
    "three-cycles",
    "three-cycles-plentiful-distractors",
)

for variant in VARIANTS:
    with GameBridge([str(BRIDGE), str(MANIFEST), variant]) as bridge:
        observation = bridge.reset("test-1", 8)
        dimensions = None
        decisions = 0
        frozen = observation.semantic_view
        while not isinstance(observation, Terminal):
            assert observation.semantic_view["cogs"] == frozen["cogs"]
            assert observation.semantic_view["reactors"] == frozen["reactors"]
            encoding = DecisionEncoding.model_validate_json(
                bridge.request({"kind": "encode"})
            )
            assert len(encoding.actions) == 25
            dimensions = dimensions or len(encoding.values)
            assert len(encoding.values) == dimensions
            action = json.loads(bridge.teacher())
            assert encoding.action_for(encoding.indices_for(action)) == action
            observation = bridge.step(
                observation.decision_id, json.dumps(action)
            ).observation
            decisions += 1
            if not isinstance(observation, Terminal) and decisions % 8 == 0:
                frozen = observation.semantic_view
        assert 8 <= decisions <= 96 and decisions % 8 == 0
        assert all(score >= 0 for score in observation.scores.values())
        print(variant, decisions, dimensions, observation.scores)
