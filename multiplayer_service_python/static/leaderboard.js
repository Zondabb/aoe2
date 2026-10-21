"use strict";

const byId = (id) => document.getElementById(id);
const pageSize = 20;
let sort = "win_rate";
let offset = 0;
let total = 0;
let controller;
let searchTimer;
let loaded = false;
let busy = false;
const countFormat = new Intl.NumberFormat("zh-CN");
const rateFormat = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 1 });

function cell(text, className = "") {
  const node = document.createElement("td");
  node.textContent = text;
  node.className = className;
  return node;
}

function showEmpty(title, description) {
  const row = document.createElement("tr");
  const message = cell("", "empty");
  message.colSpan = 5;
  const heading = document.createElement("strong");
  heading.textContent = title;
  message.append(heading, document.createTextNode(description));
  row.append(message);
  byId("players").replaceChildren(row);
}

function render(data) {
  total = data.total;
  byId("player-count").textContent = countFormat.format(data.total_players);
  byId("match-count").textContent = countFormat.format(data.completed_matches);
  byId("updated-at").textContent = data.updated_at
    ? `最近结算 ${new Date(data.updated_at).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })}`
    : "尚无已结算对局";
  byId("rate-heading").textContent = sort === "win_rate" ? "胜率 ↓" : "胜率";
  byId("wins-heading").textContent = sort === "wins" ? "胜场 ↓" : "胜场";
  byId("games-heading").textContent = sort === "games" ? "总场次 ↓" : "总场次";
  if (!data.players.length) {
    showEmpty(byId("search").value.trim() ? "没有找到这位玩家" : "等待第一位玩家上榜",
      byId("search").value.trim() ? "试试其他昵称，或清空搜索查看所有玩家。" : "加入联机匹配后，昵称会出现在这里；结束对局后自动累计战绩。");
  } else {
    const rows = data.players.map((player) => {
      const row = document.createElement("tr");
      row.append(cell(String(player.rank).padStart(2, "0"), `rank rank-col${player.rank <= 3 ? " top" : ""}`));
      const identity = cell("");
      const person = document.createElement("div");
      person.className = "player-cell";
      const avatar = document.createElement("span");
      const hash = Array.from(player.name).reduce((sum, char) => sum + char.codePointAt(0), 0);
      avatar.className = `avatar palette-${hash % 4}`;
      avatar.textContent = Array.from(player.name)[0];
      avatar.setAttribute("aria-hidden", "true");
      const name = document.createElement("span");
      name.className = "player-name";
      name.textContent = player.name;
      person.append(avatar, name);
      identity.append(person);
      row.append(identity);
      const rate = cell("", "numeric rate-cell");
      const track = document.createElement("span");
      track.className = "rate-track";
      track.setAttribute("aria-hidden", "true");
      for (let index = 0; index < 10; index++) {
        const segment = document.createElement("span");
        segment.className = `rate-segment${index < Math.round(player.win_rate / 10) && player.games ? " filled" : ""}`;
        track.append(segment);
      }
      const value = document.createElement("span");
      value.className = "rate-value";
      value.textContent = player.games ? `${rateFormat.format(player.win_rate)}%` : "—";
      rate.append(track, value);
      row.append(rate, cell(countFormat.format(player.wins), "numeric wins"), cell(countFormat.format(player.games), "numeric games"));
      return row;
    });
    byId("players").replaceChildren(...rows);
  }
  byId("page-info").textContent = total
    ? `第 ${countFormat.format(offset + 1)}–${countFormat.format(Math.min(offset + pageSize, total))} 位 · 共 ${countFormat.format(total)} 位玩家`
    : "共 0 位玩家";
}

async function load() {
  controller?.abort();
  const request = new AbortController();
  controller = request;
  busy = true;
  byId("board").setAttribute("aria-busy", "true");
  byId("refresh").disabled = true;
  byId("previous").disabled = true;
  byId("next").disabled = true;
  const timeout = setTimeout(() => request.abort("timeout"), 10000);
  try {
    const query = new URLSearchParams({ sort, q: byId("search").value.trim(), limit: pageSize, offset });
    const response = await fetch(`/api/leaderboard?${query}`, { signal: request.signal, cache: "no-store" });
    if (!response.ok) throw new Error("request_failed");
    const data = await response.json();
    if (controller !== request) return;
    if (offset && offset >= data.total) {
      offset = Math.max(0, Math.floor((data.total - 1) / pageSize) * pageSize);
      load();
      return;
    }
    render(data);
    loaded = true;
    byId("notice").hidden = true;
  } catch (error) {
    if (controller !== request) return;
    byId("notice").textContent = loaded ? "暂时无法更新，当前显示上次读取的战绩。可点击刷新重试。" : "无法读取排行榜，请检查服务连接后点击刷新重试。";
    byId("notice").hidden = false;
    if (!loaded) {
      showEmpty("排行榜暂时无法加载", "请稍后重试。");
      byId("page-info").textContent = "连接暂不可用";
    }
  } finally {
    clearTimeout(timeout);
    if (controller === request) {
      busy = false;
      byId("board").setAttribute("aria-busy", "false");
      byId("refresh").disabled = false;
      byId("previous").disabled = offset === 0;
      byId("next").disabled = offset + pageSize >= total;
    }
  }
}

document.querySelectorAll("[data-sort]").forEach((button) => button.addEventListener("click", () => {
  sort = button.dataset.sort;
  offset = 0;
  document.querySelectorAll("[data-sort]").forEach((item) => item.setAttribute("aria-pressed", String(item === button)));
  load();
}));
byId("search").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => { offset = 0; load(); }, 250);
});
byId("refresh").addEventListener("click", load);
byId("previous").addEventListener("click", () => { offset = Math.max(0, offset - pageSize); load(); });
byId("next").addEventListener("click", () => { offset += pageSize; load(); });
document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
setInterval(() => { if (!document.hidden && !busy) load(); }, 20000);
load();
