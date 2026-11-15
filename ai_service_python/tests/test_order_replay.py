"""tools/order_replay.py: sample orders put to a model outside a match, and the mandates that come out checked."""
from __future__ import annotations

import collections
import importlib.util
import json
from pathlib import Path

from brain.cabinet.premier import INTERPRET_PROMPT, interpret_schema
from test_cabinet_orders import m, read
from test_multi_agent_scheduler import completion

SPEC = importlib.util.spec_from_file_location("order_replay", Path(__file__).resolve().parents[1] / "tools" / "order_replay.py")
order_replay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(order_replay)


def asked(plan_req) -> dict:
    return json.loads(plan_req.messages[1].content)


def says(*mandates, **more):
    return completion(json.dumps(read(*mandates, **more), ensure_ascii=False))


def model(answers: dict, sent: list | None = None):
    """A model that answers each order from a script: one answer, or a list for the first and later tries."""
    turns = collections.Counter()

    def forward(plan_req):
        if sent is not None:
            sent.append(plan_req)
        text = asked(plan_req)["order"]
        script = answers[text]
        turns[text] += 1
        answer = script[min(turns[text], len(script)) - 1] if isinstance(script, list) else script
        if isinstance(answer, Exception):
            raise answer
        return answer
    return forward


def test_the_samples_cover_every_grade_and_a_right_answer_passes_each():
    samples = order_replay.load_samples()
    grades = collections.Counter(sample["grade"] for sample in samples)
    assert set(grades) == {"exact", "approx", "guess", "none"} and min(grades.values()) >= 3
    assert len({sample["text"] + sample["civ"] for sample in samples}) == len(samples)

    def right(sample):
        if not sample["accept"]:
            return says(grasp="none")
        return says(*[m(kind, subject or ("knight" if kind == "stockpile" else ""), amount or 0) for kind, subject, amount in sample["accept"][0]])

    answers = {(sample["text"], sample["civ"]): right(sample) for sample in samples}     # the same words mean different things to two civilizations
    report = order_replay.replay(samples, 1, lambda plan_req: answers[asked(plan_req)["order"], asked(plan_req)["civilization"]], clock=lambda: 0.0)
    missed = [row["text"] for row in report["samples"] if row["matched"] != 1]
    assert missed == [] and (report["usable_rate"], report["match_rate"], report["calls"]) == (1.0, 1.0, len(samples))
    assert report["grades"]["approx"] == {"orders": grades["approx"], "usable": grades["approx"], "matched": grades["approx"], "same_grade": 0}


def test_an_order_is_read_and_checked_as_in_a_match():
    sent = []
    samples = [
        {"grade": "approx", "civ": "chinese", "age": 2, "text": "囤积50个游侠", "accept": [[["stockpile", "cavalier", 50]]]},
        {"grade": "approx", "civ": "teutons", "age": 2, "text": "造10个骆驼", "accept": [[["stockpile", "knight", 10]]]},
        {"grade": "approx", "civ": "teutons", "age": 2, "text": "再来10个骆驼", "accept": [[["stockpile", "knight", 10]]]},
        {"grade": "exact", "civ": "teutons", "age": 2, "text": "进攻", "accept": [[["attack", None, None]]]},
        {"grade": "exact", "civ": "teutons", "age": 2, "text": "按兵不动", "accept": [[["hold", None, None]]]},
        {"grade": "exact", "civ": "teutons", "age": 2, "text": "查清敌人兵力", "accept": [[["scout", None, None]]]},
        {"grade": "none", "civ": "teutons", "age": 2, "text": "造10艘航母", "accept": []},
        {"grade": "none", "civ": "teutons", "age": 2, "text": "今天天气怎么样", "accept": []},
        {"grade": "none", "civ": "teutons", "age": 2, "text": "帮我写一首诗", "accept": []},
        {"grade": "exact", "civ": "teutons", "age": 2, "text": "来50个游侠", "accept": [[["stockpile", "paladin", 50]]]},
        {"grade": "exact", "civ": "teutons", "age": 2, "text": "来30个游侠", "accept": [[["stockpile", "paladin", 30]]]},
    ]
    forward = model({
        "囤积50个游侠": says(m("stockpile", "paladin", 50), grasp="approx"),                       # repaired by the catalog check
        "造10个骆驼": [says(m("stockpile", "camel", 10)), says(m("stockpile", "knight", 10), grasp="approx")],
        "再来10个骆驼": says(m("stockpile", "camel", 10)),                                         # refused twice
        "进攻": TimeoutError("model unavailable"),
        "按兵不动": completion('{"thinking": "好'),                                                # cut off
        "查清敌人兵力": says(m("attack"), thinking="敌人不强。" * 30),                              # the wrong thing, at length
        "造10艘航母": says(m("stockpile", "knight", 10), grasp="guess"),                            # obeyed nonsense
        "今天天气怎么样": says(grasp="none", thinking="This has nothing to do with the match.", decision="Not carried out."),
        "帮我写一首诗": ConnectionError("model unavailable"),                                      # no answer is not a refusal
        "来50个游侠": says(m("stockpile", "knight", 50)),                                          # the wrong unit
        "来30个游侠": says(m("stockpile", "paladin", 50)),                                         # the wrong number
    }, sent)
    report = order_replay.replay(samples, 1, forward, clock=lambda: 0.0)
    rows = {row["text"]: row["outcomes"][0] for row in report["samples"]}

    first = sent[0]
    assert first.messages[0].content.startswith(INTERPRET_PROMPT) and first.tools[0].function.parameters == interpret_schema()
    assert (first.metadata.agent, first.metadata.plan_output_tokens) == ("premier_orders", 512)
    assert (asked(first)["order"], asked(first)["civilization"], asked(first)["age"]) == ("囤积50个游侠", "chinese", 2)

    repaired = rows["囤积50个游侠"]
    assert (repaired["state"], repaired["grasp"], repaired["mandates"], repaired["named"]) == ("active", "approx", [["stockpile", "cavalier", 50, "normal"]], ["重装骑士"])
    assert repaired["notes"] == ["中国造不了游侠，改为重装骑士"] and repaired["matched"] and repaired["calls"] == 1

    again = rows["造10个骆驼"]
    assert (again["state"], again["calls"], again["sent_back"], again["matched"]) == ("active", 2, True, True)
    assert asked(sent[2])["previous"] == {"mandates": [m("stockpile", "camel", 10)], "problem": "条顿造不了 camel，也没有相近的兵种"}
    given_up = rows["再来10个骆驼"]
    assert (given_up["state"], given_up["grasp"], given_up["calls"], given_up["matched"], given_up["usable"]) == ("impossible", "none", 2, False, True)

    assert (rows["进攻"]["state"], rows["进攻"]["usable"], rows["进攻"]["matched"], rows["进攻"]["calls"]) == ("call_failed", False, False, 1)
    assert rows["按兵不动"]["usable"] is False and rows["按兵不动"]["state"] not in ("active", "impossible")
    assert (rows["查清敌人兵力"]["matched"], rows["查清敌人兵力"]["over_length"]) == (False, True)
    assert (rows["造10艘航母"]["state"], rows["造10艘航母"]["matched"]) == ("active", False)
    refused = rows["今天天气怎么样"]
    assert (refused["state"], refused["matched"], refused["chinese"], refused["mandates"]) == ("impossible", True, False, [])

    assert (rows["帮我写一首诗"]["usable"], rows["帮我写一首诗"]["matched"]) == (False, False)
    assert (rows["来50个游侠"]["state"], rows["来50个游侠"]["matched"]) == ("active", False)
    assert (rows["来30个游侠"]["state"], rows["来30个游侠"]["matched"]) == ("active", False)

    assert (report["orders"], report["calls"], report["usable"], report["matched"], report["sent_back"]) == (11, 13, 8, 3, 2)
    assert (report["usable_rate"], report["match_rate"], report["over_length"], report["not_chinese"]) == (.727, .273, 1, 1)
    assert report["states"]["active"] == 6 and report["states"]["impossible"] == 2 and report["states"]["call_failed"] == 2
    assert report["grades"]["none"] == {"orders": 3, "usable": 2, "matched": 1, "same_grade": 1}
    assert report["input_chars"] > 2000                     # the name table travels with every order


def test_the_command_reports_and_fails_below_the_asked_share(tmp_path, monkeypatch, capsys):
    samples = order_replay.load_samples()
    answers = {sample["text"]: says(grasp="none") for sample in samples}        # a model that refuses everything
    original, original_read = order_replay.replay, order_replay.read_order
    monkeypatch.setattr(order_replay.runtime_settings, "load_config", lambda path=None: None)
    monkeypatch.setattr(order_replay, "replay", lambda chosen, runs: original(chosen, runs, model(answers), lambda: 0.0))
    out = tmp_path / "report.json"

    assert order_replay.main(["--runs", "2", "--json", str(out), "--min-match", "0.5"]) == 1
    summary = json.loads(capsys.readouterr().out)
    nonsense = sum(sample["grade"] == "none" for sample in samples)
    assert (summary["orders"], summary["usable_rate"], summary["matched"]) == (2 * len(samples), 1.0, 2 * nonsense)
    assert summary["samples"][0] == {"text": "囤积50个游侠", "grade": "exact", "civ": "teutons", "matched": "0/2", "last": ["none"]}
    assert len(json.loads(out.read_text(encoding="utf-8"))["samples"][0]["outcomes"]) == 2

    assert order_replay.main(["--grade", "none", "--runs", "1", "--min-match", "1.0"]) == 0      # only the nonsense: all refused, all right
    assert json.loads(capsys.readouterr().out)["orders"] == nonsense

    monkeypatch.setattr(order_replay, "read_order", lambda sample: original_read(
        sample, model({"来点骑士": says(m("stockpile", "knight"), grasp="guess")}), lambda: 0.0))
    assert order_replay.main(["--say", "来点骑士", "--civ", "chinese", "--age", "2"]) == 0
    shown = json.loads(capsys.readouterr().out)
    assert (shown["state"], shown["grasp"], shown["mandates"], shown["notes"]) == ("active", "guess", [["stockpile", "knight", 10, "normal"]], ["没有说数量，先按 10 个"])

    empty = tmp_path / "none.json"
    empty.write_text(json.dumps({"samples": []}), encoding="utf-8")
    assert order_replay.main(["--samples", str(empty)]) == 2
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"samples": [{"grade": "exact", "civ": "teutons", "age": 2, "text": "进攻", "accept": [[["conquer", None, None]]]}]}), encoding="utf-8")
    try:
        order_replay.main(["--samples", str(bad)])
    except ValueError as error:
        assert "conquer is not a kind of mandate" in str(error)
    else:
        raise AssertionError("a sample naming an unknown kind must be refused")
