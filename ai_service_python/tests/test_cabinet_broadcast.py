"""Phase 5 of the cabinet architecture: the premier's words reach the player, cut into sentences, each line once."""
from __future__ import annotations

from brain.cabinet.broadcast import CHANGE_SPACING, MAX_SENTENCES, Broadcaster, joined, sentences
from brain.cabinet.ledger import REFUSED, UNANSWERED, UNREAD
from test_cabinet_orders import castle_town, m, ordered, read
from test_cabinet_premier import decision, ids
from test_cabinet_runtime import cabinet, stocked, town
from test_llm_commander import building, unit
from test_multi_agent_runtime import army, frame


def spoken(result) -> list[dict]:
    return result["planning"].get("broadcasts", [])


def texts(lines, kind=None) -> list[str]:
    return [line["text"] for line in lines if kind in (None, line["kind"])]


def quiet(profile="teutons"):
    """A cabinet whose broadcasts carry test ids and whose wall clock the test moves."""
    runtime = cabinet(profile)
    wall = [100.0]
    runtime.voice.stamp, runtime.voice.clock = "t", lambda: wall[0]
    return runtime, wall


# ---------------------------------------------------------------------------- cutting and handing out
def test_a_text_is_cut_at_its_sentence_ends():
    assert sentences("敌军只有少量骑士，短时间内打不到基地。黄金是瓶颈；城墙用石头！两边不冲突") == [
        "敌军只有少量骑士，短时间内打不到基地。", "黄金是瓶颈；", "城墙用石头！", "两边不冲突"]
    assert sentences(" 好。\n。。 Hold? 12.5 gold. ") == ["好。", "Hold?", "12.5 gold."]     # marks on their own are not lines
    assert sentences("") == [] and sentences(None) == [] and sentences("……！") == []
    assert joined("游侠优先", " 中国造不了游侠，改为重装骑士 ", "", "照办。") == "游侠优先。中国造不了游侠，改为重装骑士。照办。"


def test_a_broadcast_is_numbered_cut_into_lines_and_handed_out_once():
    voice = Broadcaster(stamp="t", clock=lambda: 50.0)
    assert voice.say("change", "", "  ", 0) is None                                           # nothing to read
    voice.say("change", "粮食够了。先补村民。", "村民优先；民兵稍后。", 10, since=8)
    voice.say("order", "游侠要先升帝王时代。", "先攒钱升时代", 10, order=3, about="囤积50个游侠", since=4, since_wall=47.5)
    voice.say("threat", "敌军到了门口！", "全部转去守家。", 10, since=9)
    assert voice.say("change", "又变了。", "再调一次。", 10 + CHANGE_SPACING - 1) is None       # routine news, too soon

    lines = voice.take(11)
    assert [(line["id"], line["seq"], line["kind"], line["priority"]) for line in lines] == [
        ("bt-3", 0, "thinking", 2), ("bt-3", 1, "decision", 2),                              # danger first
        ("bt-2", 0, "thinking", 1), ("bt-2", 1, "decision", 1),                              # then the answer to an order
        ("bt-1", 0, "thinking", 0), ("bt-1", 1, "thinking", 0), ("bt-1", 2, "decision", 0), ("bt-1", 3, "decision", 0)]
    assert [line.get("final", False) for line in lines] == [False, True, False, True, False, False, False, True]
    assert lines[2] == {"id": "bt-2", "seq": 0, "kind": "thinking", "text": "游侠要先升帝王时代。", "trigger": "order", "priority": 1,
                        "order": 3, "about": "囤积50个游侠"}
    assert "order" not in lines[0] and lines[3]["text"] == "先攒钱升时代"
    assert voice.take(12) == []                                                              # each line once

    events = voice.take_events()
    assert [(e["id"], e["trigger"], e["priority"], e["lines"], e["after_game_sec"]) for e in events] == [
        ("bt-3", "threat", 2, 2, 2.0), ("bt-2", "order", 1, 2, 7.0), ("bt-1", "change", 0, 4, 3.0)]
    assert (events[1]["after_wall_sec"], events[1]["order"], events[1]["about"]) == (2.5, 3, "囤积50个游侠")
    assert "after_wall_sec" not in events[0] and "order" not in events[0]
    assert events[2]["chars"] == len("粮食够了。先补村民。村民优先；民兵稍后。") and events[2]["decision"] == "村民优先；民兵稍后。"
    assert voice.take_events() == []

    assert voice.say("change", "又变了。", "再调一次。", 10 + CHANGE_SPACING).id == "bt-4"      # the pause is over
    assert voice.say("order", "答。", "办。", 10 + CHANGE_SPACING).id == "bt-5"                 # an answer never waits for it
    voice.take(80)
    voice.say("done", "一。二。三。四。五。六。", "甲。乙。丙。丁。戊。", 100)
    long = voice.take(100)
    assert [sum(line["kind"] == kind for line in long) for kind in ("thinking", "decision")] == [MAX_SENTENCES, MAX_SENTENCES]
    assert long[-1]["text"] == "丁。" and long[-1]["final"]


def test_ids_do_not_repeat_when_the_service_starts_again():
    first, later = Broadcaster(stamp="a1"), Broadcaster(stamp="a2")
    assert first.say("order", "", "办。", 0).id != later.say("order", "", "办。", 0).id
    assert Broadcaster().stamp and Broadcaster().say("order", "", "办。", 0).id.startswith("b")


# ---------------------------------------------------------------------------- answers to orders
def test_the_answer_to_an_order_is_read_out_with_what_the_catalog_changed():
    runtime, wall = quiet("chinese")
    tick = castle_town(runtime)
    order = ["囤积50个游侠"]
    assert spoken(tick(1, order)) == []                       # received, not read yet: nothing to say
    wall[0] = 103.5
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("stockpile", "paladin", 50), grasp="approx",
                                                     thinking="游侠是帝王时代的兵。中国没有这一级。", decision="改囤重装骑士，先升时代。"))
    result = tick(2, order)
    lines = spoken(result)
    assert all((line["id"], line["trigger"], line["priority"], line["order"], line["about"]) == ("bt-1", "order", 1, 1, "囤积50个游侠")
               for line in lines)
    assert texts(lines, "thinking") == ["游侠是帝王时代的兵。", "中国没有这一级。"]
    assert texts(lines, "decision") == ["改囤重装骑士，先升时代。", "中国造不了游侠，改为重装骑士。"]
    assert [line["seq"] for line in lines] == [0, 1, 2, 3] and lines[-1]["final"] and "final" not in lines[0]

    assert spoken(tick(2, order)) == lines                    # the same tick asked for again: the same response
    assert spoken(tick(3, order)) == []                       # the next tick: said already
    (event,) = [entry for kind, entry in runtime.take_journal() if kind == "broadcast"]
    assert (event["id"], event["trigger"], event["order"], event["lines"]) == ("bt-1", "order", 1, 4)
    assert (event["after_game_sec"], event["after_wall_sec"]) == (10.0, 3.5)        # from the order's arrival to the answer going out


def test_an_order_that_cannot_be_carried_out_says_so():
    runtime, _ = quiet()
    tick = castle_town(runtime)
    nonsense = ordered(runtime, tick, "造10艘航母", read(grasp="none", thinking="游戏里没有海军。", decision="这条办不了。"))
    assert texts(spoken(nonsense)) == ["游戏里没有海军。", "这条办不了。"]

    both = ["造10艘航母", "造10个骆驼"]
    tick(3, both)
    for _ in range(2):                                        # the catalog refuses the reading twice
        runtime.planning_brief("premier_orders")
        runtime.apply_plan("premier_orders", read(m("stockpile", "camel", 10), thinking="骆驼克骑兵。", decision="造骆驼。"))
    refused = spoken(tick(4, both))
    assert texts(refused, "decision") == [REFUSED, "条顿造不了 camel，也没有相近的兵种。"]
    assert all((line["order"], line["about"], line["trigger"]) == (2, "造10个骆驼", "order") for line in refused)


def test_an_order_no_model_reads_says_why_once():
    runtime, _ = quiet()
    tick = castle_town(runtime)
    attack = ["进攻"]
    assert spoken(tick(1, attack, now=100)) == [] and spoken(tick(2, attack, now=114)) == []
    told = spoken(tick(3, attack, now=115))
    assert [(line["kind"], line["text"], line["trigger"], line["order"], line.get("final")) for line in told] == [
        ("decision", UNREAD, "order", 1, True)]
    assert spoken(tick(4, attack, now=130)) == []             # said once

    runtime.planning_brief("premier_orders")
    assert not runtime.apply_plan("premier_orders", {"nonsense": True})
    assert texts(spoken(tick(5, attack, now=131))) == [UNANSWERED]                  # a model was asked now, and gave nothing usable
    assert spoken(tick(6, attack, now=140)) == []
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("attack"), thinking="兵够了。", decision="出兵。"))
    assert texts(spoken(tick(7, attack, now=141))) == ["兵够了。", "出兵。"]


def test_an_order_carried_out_is_reported():
    runtime, _ = quiet()
    tick = castle_town(runtime)                                # thirty villagers already
    lines = spoken(ordered(runtime, tick, "村民补到20个", read(m("worker_target", amount=20), thinking="人手够了。", decision="不用再补。")))
    assert [(line["trigger"], line["priority"], line["text"]) for line in lines] == [
        ("order", 1, "人手够了。"), ("order", 1, "不用再补。"), ("done", 0, "“村民补到20个”已经办完。")]
    assert [line["id"] for line in lines] == ["bt-1", "bt-1", "bt-2"] and all(line["order"] == 1 for line in lines)
    assert [line.get("final", False) for line in lines] == [False, True, True]

    # Clearing the instructions is the player's own doing: nothing is said about it.
    tick(3, ["村民补到20个", "进攻"])
    assert spoken(tick(4, [])) == []


# ---------------------------------------------------------------------------- rankings
def contested(runtime):
    """Sixty food and twenty gold: one villager or one militia, not both. Enemies are whatever the test adds."""
    def tick(number, now, *enemies):
        entities = town(12, building(3, "mill"), *army(6), *enemies)
        return runtime.tick(stocked(frame(number, entities=entities, time=now), food=60, gold=20))
    return tick


def test_a_ranking_is_read_out_only_when_it_changes_something():
    runtime, _ = quiet("chinese")
    tick = contested(runtime)
    rid = ids(tick(1, 10))
    rules = dict(runtime.premier.tiers)
    assert runtime.apply_plan("premier", decision(rules))                           # the model agrees with the rule book
    assert spoken(tick(2, 20)) == []                                                # nothing new: nothing said
    assert runtime.premier.source == "model"

    assert runtime.apply_plan("premier", decision({**rules, rid["farm"]: "hold"}, thinking="敌人还远。", decision="农田先停。"))
    lines = spoken(tick(3, 30))
    assert [(line["kind"], line["text"], line["trigger"], line["priority"]) for line in lines] == [
        ("thinking", "敌人还远。", "change", 0), ("decision", "农田先停。", "change", 0)]
    assert "order" not in lines[0] and lines[-1]["final"]

    assert runtime.apply_plan("premier", decision(rules, thinking="又变了。", decision="农田照常。"))
    assert spoken(tick(4, 40)) == []                                                # a change again, but too soon after the last
    # The posture alone is a change too, and the pause is over.
    assert runtime.apply_plan("premier", decision(rules, posture="pressure", thinking="该出手了。", decision="转入进攻。"))
    assert texts(spoken(tick(5, 30 + CHANGE_SPACING))) == ["该出手了。", "转入进攻。"]
    assert [entry["trigger"] for kind, entry in runtime.take_journal() if kind == "broadcast"] == ["change", "change"]


def test_a_ranking_made_in_view_of_a_new_danger_cuts_in_on_anything():
    runtime, _ = quiet("chinese")
    tick = contested(runtime)
    raider = unit(200, "militia", [10, 0], team=1)
    tick(1, 10)
    rules = lambda: dict(runtime.premier.tiers)

    # A ranking the model made before it saw the danger is not passed off as an answer to it.
    assert runtime.planning_brief("premier")["context"]["intel"]["threat_level"] == 0
    tick(2, 20, raider)
    assert runtime.brief.threat_level >= 2
    assert runtime.apply_plan("premier", decision(rules(), thinking="一切照旧。", decision="不用调整。"))
    assert spoken(tick(3, 21, raider)) == []

    assert runtime.planning_brief("premier")["context"]["intel"]["threat_level"] == runtime.brief.threat_level
    assert runtime.apply_plan("premier", decision(rules(), thinking="敌军到了门口。", decision="全部转去守家。"))
    alarm = spoken(tick(4, 22, raider))
    assert [(line["text"], line["trigger"], line["priority"]) for line in alarm] == [
        ("敌军到了门口。", "threat", 2), ("全部转去守家。", "threat", 2)]        # though it moved no request
    (event,) = [entry for kind, entry in runtime.take_journal() if kind == "broadcast"]
    assert event["after_game_sec"] == 2.0                                           # the danger appeared at 20 s

    # The same danger again is not news.
    runtime.planning_brief("premier")
    assert runtime.apply_plan("premier", decision(rules(), thinking="敌军还在。", decision="继续守家。"))
    assert spoken(tick(5, 23, raider)) == []
    # It goes away and comes back: news again, however soon.
    tick(6, 24)
    assert runtime.brief.threat_level < 2
    tick(7, 25, raider)
    runtime.planning_brief("premier")
    assert runtime.apply_plan("premier", decision(rules(), thinking="敌军又来了。", decision="再次守家。"))
    assert [line["trigger"] for line in spoken(tick(8, 26, raider))] == ["threat", "threat"]


def test_a_finished_match_says_nothing_more():
    runtime, _ = quiet()
    tick = castle_town(runtime)
    tick(1, ["进攻"])
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("attack")))
    runtime.field.goals["match_over"] = True
    assert spoken(tick(2, ["进攻"])) == []
