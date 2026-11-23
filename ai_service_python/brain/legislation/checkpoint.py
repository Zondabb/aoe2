"""Versioned, bounded JSON object graphs for cabinet process handoffs.

Class identifiers are resolved only against this module's explicit registry.
No pickle, dynamic imports, reducers, setters or checkpoint-provided code runs.
Restore into a freshly constructed runtime: its newly introduced constructor
defaults survive, while the old graph restores all previously existing state.
"""
from __future__ import annotations

from collections import Counter, deque
from dataclasses import MISSING, fields, is_dataclass
import json
import math

from pydantic import BaseModel

VERSION = 1
MAX_BYTES = 32 * 1024 * 1024
MAX_NODES = 150_000
MAX_DEPTH = 100


class CheckpointError(ValueError):
    pass


def _registry():
    # Imports are fixed by trusted runtime code, never by the document.
    from brain.cabinet.runtime import CabinetRuntime
    from brain.cabinet.broadcast import Broadcaster, Broadcast
    from brain.cabinet.construction import ConstructionCrew
    from brain.cabinet.departments.economy import EconomyDept
    from brain.cabinet.departments.intel import IntelDept
    from brain.cabinet.departments.general import GeneralDept
    from brain.cabinet.departments.defense import DefenseDept
    from brain.cabinet.departments.tech import TechDept
    from brain.cabinet.kernel import Kernel
    from brain.cabinet.ledger import Order, OrderLedger
    from brain.cabinet.models import Mandate, Request, IntelBrief, DeptReport
    from brain.cabinet.premier import Premier
    from brain.cabinet.treasury import Treasury
    from brain.multi_agent.runtime import MultiAgentRuntime, RoleState
    from brain.multi_agent.intel import OpponentModel
    from brain.multi_agent.tactics import TargetPlanner
    from brain.multi_agent.combat_model import Profile
    from brain.llm_commander import LlmCommander, Strategy, ScoutMission, GatherApproach, _DecisionFrame
    from brain.profile_loader import CivAiProfile
    from protocol.models import (ChatCompletionRequest, ChatCompletionResponse, ChatCompletionChoice,
        ChatMetadata, ChatMessage, ChatTool, ChatToolFunction, ChatUsage, Observation,
        Economy, Derived, Progression, GameEvent, Command, DebugEntry)
    classes = (CabinetRuntime, Broadcaster, Broadcast, ConstructionCrew, EconomyDept,
        IntelDept, GeneralDept, DefenseDept, TechDept, Kernel, Order, OrderLedger,
        Mandate, Request, IntelBrief, DeptReport, Premier, Treasury, MultiAgentRuntime,
        RoleState, OpponentModel, TargetPlanner, Profile, LlmCommander, Strategy,
        ScoutMission, GatherApproach, _DecisionFrame, CivAiProfile, ChatCompletionRequest,
        ChatCompletionResponse, ChatCompletionChoice, ChatMetadata, ChatMessage, ChatTool,
        ChatToolFunction, ChatUsage, Observation, Economy, Derived, Progression,
        GameEvent, Command, DebugEntry)
    return {cls.__module__ + "." + cls.__name__: cls for cls in classes}


def _json_check(value):
    """Bound raw input before traversing it or invoking any model validation."""
    count = 0
    def walk(item, depth):
        nonlocal count
        count += 1
        if depth > MAX_DEPTH or count > MAX_NODES * 20:
            raise CheckpointError("checkpoint complexity limit")
        if type(item) in (str, int, bool, type(None)):
            return
        if type(item) is float and math.isfinite(item):
            return
        if type(item) is list:
            for child in item:
                walk(child, depth + 1)
            return
        if type(item) is dict and all(type(key) is str for key in item):
            for child in item.values():
                walk(child, depth + 1)
            return
        raise CheckpointError("checkpoint is not plain finite JSON")
    walk(value, 0)
    if len(json.dumps(value, ensure_ascii=True, allow_nan=False).encode("utf-8")) > MAX_BYTES:
        raise CheckpointError("checkpoint byte limit")


def _attribute(cls, name):
    if type(name) is not str or not name.isidentifier() or name.startswith("__"):
        raise CheckpointError("invalid state attribute")
    if name == "clock" or callable(getattr(cls, name, None)) or isinstance(getattr(cls, name, None), property):
        raise CheckpointError("checkpoint cannot replace executable attributes")


def export_checkpoint(runtime) -> dict:
    registry = _registry()
    nodes, seen = [], {}

    def encode(value, depth=0):
        if depth > MAX_DEPTH:
            raise CheckpointError("checkpoint graph depth limit")
        if type(value) in (str, int, bool, type(None)):
            return value
        if type(value) is float:
            if not math.isfinite(value):
                raise CheckpointError("non-finite state")
            return value
        identity = id(value)
        if identity in seen:
            return {"ref": seen[identity]}
        if len(nodes) >= MAX_NODES:
            raise CheckpointError("checkpoint node limit")
        index = seen[identity] = len(nodes)
        node = {}
        nodes.append(node)
        kind = type(value)
        if kind in (list, tuple, set, frozenset, deque):
            node.update(kind=kind.__name__, items=[encode(v, depth + 1) for v in value])
            if kind is deque:
                node["maxlen"] = value.maxlen
        elif kind in (dict, Counter):
            node.update(kind=kind.__name__, items=[[encode(k, depth + 1), encode(v, depth + 1)] for k, v in value.items()])
        else:
            class_id = kind.__module__ + "." + kind.__name__
            if registry.get(class_id) is not kind:
                raise CheckpointError("unregistered state class: " + class_id)
            if isinstance(value, BaseModel):
                node.update(kind="model", cls=class_id,
                            data=encode(vars(value), depth + 1),
                            extra=encode(value.__pydantic_extra__, depth + 1))
            else:
                attrs = {}
                for key, item in vars(value).items():
                    # Clock is a local capability, not data from a worker.
                    if key == "clock" and kind.__name__ == "Broadcaster":
                        continue
                    _attribute(kind, key)
                    attrs[key] = encode(item, depth + 1)
                node.update(kind="object", cls=class_id, attrs=attrs)
        return {"ref": index}

    root = encode(runtime)
    result = {"version": VERSION, "root": root, "nodes": nodes}
    _json_check(result)
    return result


def restore_checkpoint(checkpoint: dict, runtime):
    """Restore a trusted-shape data graph into a freshly constructed cabinet.

    The caller must discard ``runtime`` if validation raises; restoration is
    intended for a candidate process, never in-place on the committed process.
    """
    _json_check(checkpoint)
    if type(checkpoint) is not dict or set(checkpoint) != {"version", "root", "nodes"} or type(checkpoint["version"]) is not int or checkpoint["version"] != VERSION:
        raise CheckpointError("unsupported checkpoint version")
    nodes = checkpoint["nodes"]
    if type(nodes) is not list or not nodes or len(nodes) > MAX_NODES:
        raise CheckpointError("invalid checkpoint nodes")
    registry = _registry()
    cabinet_id = "brain.cabinet.runtime.CabinetRuntime"
    if type(runtime) is not registry[cabinet_id] or checkpoint["root"] != {"ref": 0}:
        raise CheckpointError("checkpoint root must be a cabinet")
    if type(nodes[0]) is not dict or nodes[0].get("cls") != cabinet_id or nodes[0].get("kind") != "object":
        raise CheckpointError("checkpoint root must be a cabinet")
    # These constructor-created singleton objects carry defaults from the new
    # source version. Reusing them also preserves references in new defaults.
    seeds = [runtime, runtime.field, runtime.treasury, runtime.premier, runtime.voice,
        runtime.ledger, runtime.crew, *runtime.departments, runtime.field.validator,
        runtime.field.kernel, runtime.field.intel, runtime.field._targets]
    defaults = {type(obj): obj for obj in seeds}
    reused, built, busy = set(), {}, set()

    def decode(value, depth=0):
        if depth > MAX_DEPTH:
            raise CheckpointError("checkpoint graph depth limit")
        if type(value) in (str, int, bool, float, type(None)):
            return value
        if type(value) is not dict or set(value) != {"ref"} or type(value["ref"]) is not int:
            raise CheckpointError("invalid checkpoint reference")
        index = value["ref"]
        if not 0 <= index < len(nodes):
            raise CheckpointError("checkpoint reference out of bounds")
        if index in built:
            return built[index]
        if index in busy:
            raise CheckpointError("cyclic immutable checkpoint node")
        busy.add(index)
        node = nodes[index]
        if type(node) is not dict:
            raise CheckpointError("invalid checkpoint node")
        kind = node.get("kind")
        if kind in ("object", "model"):
            cls = registry.get(node.get("cls"))
            if cls is None:
                raise CheckpointError("unregistered checkpoint class")
            if kind == "model":
                if set(node) != {"kind", "cls", "data", "extra"} or not issubclass(cls, BaseModel):
                    raise CheckpointError("invalid model node")
                result = cls.model_construct()
                built[index] = result
                data = decode(node["data"], depth + 1)
                extra = decode(node["extra"], depth + 1)
                if type(data) is not dict or set(data) != set(cls.model_fields) or (extra is not None and type(extra) is not dict):
                    raise CheckpointError("invalid model fields")
                object.__setattr__(result, "__dict__", data)
                object.__setattr__(result, "__pydantic_extra__", extra)
                object.__setattr__(result, "__pydantic_fields_set__", set(data))
                # Validate without replacing shared observation/container refs.
                cls.model_validate(result.model_dump(mode="python"))
            else:
                if set(node) != {"kind", "cls", "attrs"} or issubclass(cls, BaseModel) or type(node["attrs"]) is not dict:
                    raise CheckpointError("invalid object node")
                if cls in defaults and cls not in reused:
                    result = defaults[cls]
                    reused.add(cls)
                else:
                    result = object.__new__(cls)
                    if is_dataclass(cls):
                        for field in fields(cls):
                            if field.default is not MISSING:
                                vars(result)[field.name] = field.default
                            elif field.default_factory is not MISSING:
                                vars(result)[field.name] = field.default_factory()
                built[index] = result
                for key, item in node["attrs"].items():
                    _attribute(cls, key)
                    vars(result)[key] = decode(item, depth + 1)
        else:
            expected = {"kind", "items", "maxlen"} if kind == "deque" else {"kind", "items"}
            if set(node) != expected or type(node.get("items")) is not list:
                raise CheckpointError("invalid collection node")
            items = node["items"]
            if kind in ("dict", "Counter"):
                result = {} if kind == "dict" else Counter()
                built[index] = result
                for pair in items:
                    if type(pair) is not list or len(pair) != 2:
                        raise CheckpointError("invalid mapping entry")
                    key = decode(pair[0], depth + 1)
                    if key in result:
                        raise CheckpointError("duplicate mapping key")
                    result[key] = decode(pair[1], depth + 1)
            elif kind in ("list", "set", "deque"):
                if kind == "deque":
                    maxlen = node["maxlen"]
                    if maxlen is not None and (type(maxlen) is not int or not 0 <= maxlen <= MAX_NODES or len(items) > maxlen):
                        raise CheckpointError("invalid deque bound")
                    result = deque(maxlen=maxlen)
                else:
                    result = [] if kind == "list" else set()
                built[index] = result
                for item in items:
                    (result.add if kind == "set" else result.append)(decode(item, depth + 1))
            elif kind in ("tuple", "frozenset"):
                result = (tuple if kind == "tuple" else frozenset)(decode(item, depth + 1) for item in items)
                built[index] = result
            else:
                raise CheckpointError("unknown collection kind")
        busy.remove(index)
        return result

    try:
        result = decode(checkpoint["root"])
        if len(built) != len(nodes):
            raise CheckpointError("unreachable checkpoint nodes")
        if result is not runtime or result.field.kernel.listener is not result.field:
            raise CheckpointError("invalid runtime references")
        if result.field.kernel.validator is not result.field.validator or result.crew.field is not result.field or result.crew.treasury is not result.treasury:
            raise CheckpointError("invalid shared runtime references")
        for name, dept in zip(("economy", "intel", "general", "defense", "tech"), result.departments, strict=True):
            if dept is not getattr(result, name) or dept.field is not result.field or dept.treasury is not result.treasury:
                raise CheckpointError("invalid department references")
        return result
    except (TypeError, KeyError, AttributeError, RecursionError, ValueError) as exc:
        if isinstance(exc, CheckpointError):
            raise
        raise CheckpointError("invalid checkpoint state: " + type(exc).__name__) from exc
