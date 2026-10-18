#!/usr/bin/env python3
"""Read-only, dependency-free viewer for multi-agent model I/O and issued commands."""
from __future__ import annotations

import argparse
from collections import Counter, deque
import json
import os
from pathlib import Path
import sys
import time

DEFAULT_LOG = Path(__file__).resolve().parents[1] / "logs" / "multi_agent.jsonl"
RESULTS = {"model_result", "model_failed"}
ROLES = dict(commander="总指挥", construction="建设", economy="经济", technology="科技", scout="侦察", combat="战斗", defense="城墙防守")
STATES = dict(applied="计划已应用", invalid_plan="计划无效", plan_expired="计划过期", goal_changed="目标已变化", session_closed="对局已关闭", match_over="对局结束")
OPS = dict(move="移动", attack="攻击", gather="采集", train="训练", build="参与建造", place_building="放置建筑", place_wall="建造整排城墙", set_gate_state="调整城门", stop="停止", research_age="升级时代", cancel_research_age="取消时代升级", research_technology="研究科技", cancel_technology="取消科技", noop="不操作")


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def context_from(io, request):
    messages = (io.get("input") or {}).get("messages") or request.get("messages") or []
    for message in reversed(messages):
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        try:
            context = json.loads(message.get("content") or "")
        except (ValueError, TypeError):
            continue
        if isinstance(context, dict):
            return context
    return {}


def show_result(row, io, request, full):
    role = row.get("agent", "?")
    state = row.get("state", row.get("reason", "未知"))
    label = "调用失败" if row.get("event") == "model_failed" else STATES.get(state, state)
    if state == "applied" and row.get("changed_fields") == []:
        label += "（参数未变）"
    print(f"\n【LLM 高层计划】{ROLES.get(role, role)} ({role}) | 队伍 {row.get('team', '?')} | 游戏 {row.get('sim_time', '?')} 秒 | 耗时 {row.get('elapsed_ms', '?')} ms | {label}")
    print(f"  request_id: {row.get('request_id', '未记录')} | 对局: {row.get('match_id', '?')}")
    context = context_from(io, request)
    observation = context.get("observation") or context
    economy, progression = observation.get("economy") or {}, observation.get("progression") or {}
    force = context.get("force_summary") or {}
    print(f"  输入摘要: 资源 {compact({k: economy[k] for k in ('food', 'wood', 'gold', 'stone') if k in economy})} | 时代 {progression.get('age', context.get('age', '未记录'))}")
    if force:
        print(f"  兵力/单位总量: {compact(force)}")
    elif context:
        counts = {k: len(context[k]) for k in ("workers", "units", "buildings", "visible_enemies") if isinstance(context.get(k), list)}
        if not counts and isinstance(observation.get("entities"), list):
            counts = dict(Counter(e.get("def_id", "unknown") for e in observation["entities"] if isinstance(e, dict)))
        print(f"  旧版上下文样本数量（不代表总量）: {compact(counts)}")
    else:
        print("  输入上下文未记录；无法从当前日志恢复。")
    print(f"  输出计划: {compact(row.get('plan'))}")
    print(f"  解析状态: {row.get('parse_state', '旧日志未记录')}")
    if not isinstance(row.get("plan"), dict) and io.get("output"):
        output = io["output"]
        choices = output.get("choices") or []
        message = output.get("message") or (choices[0].get("message", {}) if choices else {})
        content = message.get("content") or compact(output)
        print(f"  原始输出片段: {str(content).replace(chr(10), ' ')[:240]}")
    changes = row.get("changed_fields")
    print(f"  实际变更字段: {compact(changes) if changes is not None else '旧日志未记录'}")
    previous = context.get("plan") or {}
    for key in changes or []:
        print(f"    {key}: {compact(previous.get(key))} → {compact((row.get('plan') or {}).get(key))}")
    effect = "改变参数" if changes else "确认原计划" if changes == [] else "已应用，旧日志未记录参数差异"
    if state != "applied":
        effect = "未生效"
    print(f"  本次工作: {effect}；这是高层计划，具体单位指令由执行器生成。")
    if full:
        for label, value in (("真实发送 JSON（含完整 messages）", io.get("input")), ("模型原始响应", io.get("output"))):
            print(f"  {label}:\n{json.dumps(value, ensure_ascii=False, indent=2) if value is not None else '未记录'}")


def show_commands(row):
    commands = row.get("commands") or []
    print(f"\n【执行器下发】队伍 {row.get('team', '?')} | 游戏 {row.get('sim_time', '?')} 秒 | observation_seq={row.get('observation_seq', '?')} | {len(commands)} 条")
    print("  仅表示下发，未证明执行成功；不能按时间相邻归因于某次 LLM 调用。")
    print(f"  对局: {row.get('match_id', '?')}")
    names = dict(unit_id="单位", builder_id="建造者", building_id="建筑", target_id="目标", unit_def_id="单位类型", building_def_id="建筑类型", technology_id="科技", pos="位置", start="墙起点", end="墙终点", include_gate="包含城门", orientation="方向", gate_state="城门状态")
    for command in commands:
        if isinstance(command, dict):
            details = " | ".join(f"{label}={compact(command[key])}" for key, label in names.items() if key in command)
            op = command.get("op", "?")
            print(f"  {OPS.get(op, op)} ({op}) | {details} | command_id={command.get('command_id', '未记录')}")


class LogReader:
    """Keep incomplete UTF-8/JSON lines until completed; reopen to permit rotation."""

    def __init__(self, path):
        self.path, self.offset, self.pending = path, 0, b""
        self.identity, self.prefix = None, b""

    def read(self, final=False):
        try:
            with self.path.open("rb") as stream:
                stat = os.fstat(stream.fileno())
                identity = (stat.st_dev, stat.st_ino)
                rotated = self.identity is not None and (identity != self.identity or stat.st_size < self.offset or stream.read(len(self.prefix)) != self.prefix)
                if rotated:
                    self.offset, self.pending, self.prefix = 0, b"", b""
                self.identity = identity
                if not self.prefix:
                    stream.seek(0)
                    self.prefix = stream.read(min(128, stat.st_size))
                stream.seek(self.offset)
                data = self.pending + stream.read()
                self.offset = stream.tell()
        except (FileNotFoundError, PermissionError):
            return [], False
        lines = data.split(b"\n")
        self.pending = lines.pop()
        if final and self.pending:
            lines.append(self.pending)
            self.pending = b""
        rows = []
        for line in lines:
            try:
                row = json.loads(line.decode("utf-8-sig"))
                if isinstance(row, dict):
                    rows.append(row)
            except (ValueError, UnicodeError):
                pass
        return rows, rotated


class Viewer:
    def __init__(self, args):
        self.args, self.io, self.requests, self.results = args, {}, {}, {}
        self.waiting = {}

    def ingest(self, rows, initial=False):
        recent, last_commands = deque(maxlen=self.args.last), None
        for row in rows:
            request_id, event = row.get("request_id"), row.get("event")
            # Command batches have no request_id; never pretend they belong to a call.
            if self.args.request_id and request_id != self.args.request_id:
                continue
            if event == "llm_io":
                self.io[request_id] = row
            elif event == "model_request":
                self.requests[request_id] = row
            elif event in RESULTS:
                self.results[request_id] = row
                if initial:
                    recent.append(request_id)
                else:
                    self.waiting[request_id] = time.monotonic()
            elif self.args.commands and event == "tick" and row.get("commands"):
                if initial:
                    last_commands = row
                else:
                    show_commands(row)
        if initial:
            for request_id in recent:
                self.show(request_id)
            if last_commands:
                show_commands(last_commands)
            if not recent:
                print("尚无匹配的模型结果。")
            if self.args.request_id and self.args.commands:
                print("request_id 精确筛选时不显示无法关联到该调用的执行器批次。")
        self.flush()
        # Retain enough recent calls for result/I/O ordering without unbounded growth.
        for cache in (self.io, self.requests, self.results):
            while len(cache) > max(256, self.args.last):
                cache.pop(next(iter(cache)))

    def show(self, request_id):
        show_result(self.results[request_id], self.io.get(request_id, {}), self.requests.get(request_id, {}), self.args.full_io)

    def flush(self):
        for request_id, started in list(self.waiting.items()):
            if request_id in self.io or time.monotonic() - started >= 1:
                self.show(request_id)
                del self.waiting[request_id]


def main():
    parser = argparse.ArgumentParser(description="只读观察 LLM 输入、输出、计划变化和执行器下发指令。")
    parser.add_argument("path", nargs="?", type=Path, default=DEFAULT_LOG, help="JSONL 文件，默认 logs/multi_agent.jsonl")
    parser.add_argument("--last", type=int, default=7, help="启动时显示最近 N 次模型结果（默认 7）")
    parser.add_argument("--follow", action="store_true", help="持续读取新增记录，支持截断和日志轮转")
    parser.add_argument("--commands", action="store_true", help="另显示执行器命令，启动时仅最近一个非空批次")
    parser.add_argument("--full-io", action="store_true", help="显示真实发送 JSON 和模型原始响应")
    parser.add_argument("--request-id", help="按完整 request_id 精确筛选模型调用")
    args = parser.parse_args()
    if args.last < 1:
        parser.error("--last 必须大于 0")
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
    if not args.path.is_file() and not args.follow:
        parser.error(f"日志文件不存在: {args.path}")
    print(f"只读日志: {args.path.resolve()}")
    reader, viewer = LogReader(args.path), Viewer(args)
    rows, _ = reader.read(final=not args.follow)
    viewer.ingest(rows, initial=True)
    if args.follow:
        print("\n实时观察中，Ctrl+C 退出。")
        try:
            while True:
                time.sleep(0.3)
                rows, rotated = reader.read()
                if rotated:
                    print("\n日志已轮转或截断，继续读取新文件。")
                viewer.ingest(rows)
        except KeyboardInterrupt:
            print("\n已停止观察。")


if __name__ == "__main__":
    main()
