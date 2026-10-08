/* The custom elements a Stampdrill HTML test report is written in, and the page
   they draw. Every number is in the markup of the report itself, in attributes;
   this module only reads that tree and lays it out, which is why the same file
   a build server parses is the file a person opens. Nothing is uploaded, and
   nothing is fetched except the stylesheet beside this file.

   Copyright 2026 Siamand Maroufi. This Source Code Form is subject to the terms
   of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
   distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. */

const STYLESHEET = new URL("./report.css", import.meta.url).href;
const drawn = new WeakSet();

// MARK: the elements

/** The whole run. It reads its subtree and replaces it with the page. */
class StampReport extends HTMLElement {
  connectedCallback() { draw(this, page); }
}

/* A plan or a load test can also stand alone in a page of someone else's.
   Inside a report the parent draws it, so there it does nothing. */
class StampPlan extends HTMLElement {
  connectedCallback() { if (!inReport(this)) draw(this, plan); }
}

class StampLoad extends HTMLElement {
  connectedCallback() { if (!inReport(this)) draw(this, load); }
}

/** The data elements: they carry measurements and draw nothing. Defining them
    is what makes :defined true, so a half loaded page shows no raw data. */
class StampData extends HTMLElement {}

const DATA = [
  "iteration", "dimension", "step", "concurrently", "actor", "request", "check", "expect", "print", "failure",
  "timings", "timing", "metrics", "thresholds", "threshold", "series", "second", "requests", "request-stats",
  "failures", "load-failure",
];

function define(tag, constructor) {
  if (!customElements.get(tag)) customElements.define(tag, constructor);
}

function inReport(node) {
  return node.parentElement != null && node.parentElement.closest("stamp-report") != null;
}

/** Builds the page from the data, then swaps the data out for it. A report that
    cannot be read is left alone and said out loud, rather than half drawn. */
function draw(host, build) {
  const run = () => {
    if (drawn.has(host)) return;
    drawn.add(host);
    try {
      host.replaceChildren(build(host));
    } catch (error) {
      drawn.delete(host);
      console.error("This is not a Stampdrill report this version can draw:", error);
    }
  };
  // The script may be loaded in a way that runs it before the data is parsed.
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run, { once: true });
  else run();
}

/** An embedder only has to add the script tag; the look comes along with it. */
function stylesheet() {
  for (const sheet of document.querySelectorAll('link[rel~="stylesheet"]')) {
    if (sheet.href === STYLESHEET || sheet.href.endsWith("/report.css")) return;
  }
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = STYLESHEET;
  (document.head || document.documentElement).append(link);
}

// MARK: the page

function page(report) {
  const wrap = element("div", "wrap");
  wrap.append(
    heading(report),
    paragraph("meta", [text(report.getAttribute("started-at") || ""), text(" · "), code(report.getAttribute("generator") || "")]),
    totals(report),
  );
  for (const node of children(report, "plan", "load")) {
    wrap.append(kind(node) === "plan" ? plan(node) : load(node));
  }
  wrap.append(footer(report));
  return wrap;
}

function heading(report) {
  const h1 = element("h1");
  h1.append(pill(passed(report)), text(" Stampdrill test report"));
  return h1;
}

function totals(report) {
  const list = element("dl", "totals");
  const counts = [];
  if (number(report, "plans") > 0) {
    counts.push(["Plans", report.getAttribute("plans")], ["Iterations", report.getAttribute("iterations")]);
  }
  if (number(report, "loads") > 0) counts.push(["Load tests", report.getAttribute("loads")]);
  counts.push(["Requests", report.getAttribute("requests")], ["Checks", report.getAttribute("checks")]);
  for (const [name, value] of counts) list.append(total(name, value));
  list.append(total("Checks failed", report.getAttribute("checks-failed"), number(report, "checks-failed") > 0));
  list.append(total("Time", milliseconds(report.getAttribute("ms"))));
  return list;
}

function total(name, value, bad) {
  const box = element("div");
  box.append(element("dt", null, name));
  box.append(element("dd", bad ? "bad" : null, value == null ? "" : String(value)));
  return box;
}

function plan(node) {
  const section = element("section", "plan " + passed(node));
  const head = element("header");
  head.append(element("h2", null, node.getAttribute("name")), element("span", "file", node.getAttribute("file")));
  section.append(head);
  section.append(paragraph("counts", [text([
    count(node, "iterations", "iteration"),
    count(node, "requests", "request"),
    count(node, "checks", "check") + (number(node, "checks-failed") > 0 ? `, ${node.getAttribute("checks-failed")} failed` : ""),
    milliseconds(node.getAttribute("ms")),
  ].join(" · "))]));

  const iterations = children(node, "iteration");
  for (const iteration of iterations) section.append(iterationBlock(iteration, iterations.length === 1));
  const timings = child(node, "timings");
  if (timings) {
    section.append(element("h3", "section-title", "Average and p95, by request"));
    section.append(bars(children(timings, "timing")));
  }
  return section;
}

function iterationBlock(node, only) {
  const details = element("details", passed(node));
  if (!boolean(node, "passed") || only) details.open = true;
  const summary = element("summary");
  summary.append(element("span", "dot"), text(node.getAttribute("label") || ""));
  const dimensions = children(node, "dimension")
    .map((d) => `${d.getAttribute("name")}=${d.getAttribute("value")}`).join(", ");
  if (dimensions && dimensions !== node.getAttribute("label")) {
    summary.append(element("span", "dims", dimensions));
  }
  summary.append(element("span", "time", milliseconds(node.getAttribute("ms"))));
  details.append(summary, list(node));
  return details;
}

/** The events of a step, an actor or an iteration, as one list. */
function list(node) {
  const items = element("ul");
  for (const event of children(node, "step", "concurrently", "request", "expect", "print", "failure")) {
    items.append(eventItem(event));
  }
  return items;
}

function eventItem(node) {
  switch (kind(node)) {
    case "step": {
      const item = element("li", passed(node));
      item.append(element("span", "step", node.getAttribute("title")));
      if (number(node, "attempts") > 1) {
        item.append(element("span", "status", `after ${node.getAttribute("attempts")} attempts`));
      }
      item.append(element("span", "status", milliseconds(node.getAttribute("ms"))), list(node));
      return item;
    }
    case "concurrently": return concurrently(node);
    case "request": {
      const item = element("li", passed(node));
      item.append(code(`${node.getAttribute("method") || ""} ${node.getAttribute("name")}`.trim()));
      if (node.hasAttribute("status")) {
        item.append(element("span", "status", `${node.getAttribute("status")} · ${milliseconds(node.getAttribute("ms"))}`));
      }
      if (node.getAttribute("error")) item.append(element("div", "message", node.getAttribute("error")));
      const failed = children(node, "check").filter((check) => !boolean(check, "passed"));
      if (failed.length) {
        const inner = element("ul");
        for (const check of failed) inner.append(eventItem(check));
        item.append(inner);
      }
      return item;
    }
    case "check":
    case "expect": {
      const item = element("li", passed(node));
      item.append(code((kind(node) === "expect" ? "expect " : "") + node.getAttribute("source")));
      if (node.getAttribute("message")) item.append(element("div", "message", node.getAttribute("message")));
      return item;
    }
    case "print": return element("li", "note", null, [code(node.textContent)]);
    case "failure": {
      const item = element("li", "failed", node.textContent);
      item.append(element("span", "status", `line ${node.getAttribute("line")}`));
      return item;
    }
    default: return element("li");
  }
}

/** Actors on one clock: who started when, and how long each one took. */
function concurrently(node) {
  const item = element("li", passed(node));
  item.append(element("span", "step", node.getAttribute("title")));
  item.append(element("span", "status", `${node.getAttribute("actors")} actors at once · ${milliseconds(node.getAttribute("ms"))}`));

  const span = Math.max(1, number(node, "ms"));
  const requests = descendants(node, "request");
  const first = requests.length ? number(requests[0], "at") : 0;
  const lanes = element("div", "lanes");
  for (const actor of children(node, "actor")) {
    const lane = element("div", "lane");
    lane.append(element("span", "lane-name", `actor ${actor.getAttribute("index")}`));
    const track = element("div", "lane-track");
    for (const request of descendants(actor, "request")) {
      const bar = element("span", "lane-bar" + (boolean(request, "passed") ? "" : " failed"));
      const at = number(request, "at") - first;
      bar.style.left = `${(at / span) * 100}%`;
      bar.style.width = `${(number(request, "ms") / span) * 100}%`;
      bar.title = `${request.getAttribute("name")}: started ${at} ms in, took ${request.getAttribute("ms")} ms`;
      track.append(bar);
    }
    lane.append(track);
    lanes.append(lane);
  }
  const scale = element("div", "lane-scale");
  scale.append(element("span", null, "0 ms"), element("span", null, `${node.getAttribute("ms")} ms`));
  lanes.append(scale);
  item.append(lanes);

  const inner = element("ul");
  for (const actor of children(node, "actor")) {
    const line = element("li", passed(actor));
    line.append(element("span", "step", `actor ${actor.getAttribute("index")}`));
    if (number(actor, "ms") > 0) line.append(element("span", "status", milliseconds(actor.getAttribute("ms"))));
    line.append(list(actor));
    inner.append(line);
  }
  item.append(inner);
  return item;
}

// MARK: load tests

function load(node) {
  const metrics = child(node, "metrics");
  const section = element("section", "plan " + passed(node));
  const head = element("header");
  head.append(element("h2", null, node.getAttribute("name")), element("span", "file", node.getAttribute("file")),
              element("span", "pill " + passed(node), "load test"));
  section.append(head);
  section.append(paragraph("counts", [text([
    `${node.getAttribute("users")} users`,
    `${node.getAttribute("iterations")} iterations`,
    milliseconds(node.getAttribute("ms")),
  ].join(" · "))]));

  if (metrics) {
    const tiles = element("dl", "metrics");
    tiles.append(
      total("Requests", metrics.getAttribute("requests")),
      total("Per second", round(metrics.getAttribute("rps"), 1)),
      total("Errors", `${round(number(metrics, "error-rate") * 100, 2)}%`, number(metrics, "failed") > 0),
      total("p50", `${round(metrics.getAttribute("p50"), 0)} ms`),
      total("p95", `${round(metrics.getAttribute("p95"), 0)} ms`),
      total("p99", `${round(metrics.getAttribute("p99"), 0)} ms`),
      total("Max", `${round(metrics.getAttribute("max"), 0)} ms`),
      total("Checks", `${number(metrics, "checks") - number(metrics, "checks-failed")}/${metrics.getAttribute("checks")}`,
            number(metrics, "checks-failed") > 0),
    );
    section.append(tiles);
  }

  const series = child(node, "series");
  const seconds = series ? children(series, "second") : [];
  if (seconds.length) {
    const charts = element("div", "charts");
    charts.append(chart(seconds, "requests", "Requests a second", ""));
    charts.append(chart(seconds, "p95", "p95 latency", " ms", "var(--bad)"));
    charts.append(chart(seconds, "users", "Active users", "", "var(--ok)"));
    if (seconds.some((second) => number(second, "errors") > 0)) {
      charts.append(chart(seconds, "errors", "Errors a second", "", "var(--bad)"));
    }
    section.append(charts);
  }

  const requests = child(node, "requests");
  if (requests) {
    section.append(element("h3", "section-title", "Average and p95, by request"));
    section.append(bars(children(requests, "request-stats")));
  }

  const thresholds = child(node, "thresholds");
  if (thresholds) section.append(thresholdTable(children(thresholds, "threshold")));

  const failures = child(node, "failures");
  if (failures) {
    section.append(element("h3", "section-title", "What went wrong"));
    const items = element("ul");
    for (const failure of children(failures, "load-failure")) {
      const item = element("li", "failed", failure.textContent);
      item.append(element("span", "status", `× ${failure.getAttribute("count")}`));
      items.append(item);
    }
    section.append(items);
  }
  return section;
}

function thresholdTable(rows) {
  const table = element("table");
  const head = element("thead");
  const headRow = element("tr");
  for (const name of ["Threshold", "Measured", "Verdict"]) headRow.append(element("th", null, name));
  head.append(headRow);
  const body = element("tbody");
  for (const row of rows) {
    const line = element("tr");
    line.append(element("td", null, null, [code(row.getAttribute("source"))]));
    const metric = row.getAttribute("metric");
    const measured = metric === "errors" || metric === "checks"
      ? `${round(number(row, "measured") * 100, 2)}%`
      : round(row.getAttribute("measured"), 2);
    line.append(element("td", null, measured));
    line.append(element("td", null, null, [element("span", "pill " + passed(row), passed(row))]));
    body.append(line);
  }
  table.append(head, body);
  return table;
}

// MARK: charts

const SVG = "http://www.w3.org/2000/svg";

/** One measurement a second, as a filled line. */
function chart(rows, field, title, unit, tone = "var(--accent)") {
  const values = rows.map((row) => number(row, field));
  const max = Math.max(1, ...values);
  const step = 600 / Math.max(1, values.length - 1);
  const points = values.map((value, index) => [step * index, 130 - (value / max) * 110]);

  const box = element("div", "chart");
  box.append(element("h3", null, title), element("p", "peak", `peak ${round(max, 2)}${unit}`));

  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("viewBox", "0 0 600 140");
  svg.setAttribute("preserveAspectRatio", "none");
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", `${title}, peaking at ${round(max, 2)}${unit}`);
  for (const y of [20, 75, 130]) {
    const line = document.createElementNS(SVG, "line");
    line.setAttribute("class", "grid");
    line.setAttribute("x1", "0");
    line.setAttribute("x2", "600");
    line.setAttribute("y1", String(y));
    line.setAttribute("y2", String(y));
    line.setAttribute("vector-effect", "non-scaling-stroke");
    svg.append(line);
  }
  const area = document.createElementNS(SVG, "polygon");
  area.setAttribute("fill", tone);
  area.setAttribute("opacity", "0.14");
  area.setAttribute("points", `0,130 ${points.map(([x, y]) => `${x},${y}`).join(" ")} ${step * (values.length - 1)},130`);
  const line = document.createElementNS(SVG, "polyline");
  line.setAttribute("fill", "none");
  line.setAttribute("stroke", tone);
  line.setAttribute("stroke-width", "2");
  line.setAttribute("stroke-linejoin", "round");
  line.setAttribute("stroke-linecap", "round");
  line.setAttribute("vector-effect", "non-scaling-stroke");
  line.setAttribute("points", points.map(([x, y]) => `${x},${y}`).join(" "));
  svg.append(area, line);
  box.append(svg);

  const scale = element("p", "chart-scale");
  scale.append(element("span", null, "0s"), element("span", null, `${rows[rows.length - 1].getAttribute("at")}s`));
  box.append(scale);
  return box;
}

/** A bar per request: the darker bar is the average, the lighter one p95. */
function bars(rows) {
  const max = Math.max(1, ...rows.map((row) => number(row, "p95")));
  const box = element("div", "bars");
  for (const row of rows) {
    const line = element("div", "bar-row");
    line.append(code(row.getAttribute("name")));
    const track = element("div", "bar-track");
    const p95 = element("span", "bar second");
    p95.style.width = `${(number(row, "p95") / max) * 100}%`;
    p95.title = `p95 ${row.getAttribute("p95")} ms`;
    const average = element("span", "bar");
    average.style.width = `${(number(row, "average") / max) * 100}%`;
    average.title = `average ${row.getAttribute("average")} ms`;
    track.append(p95, average);
    const value = [
      row.hasAttribute("count") ? `×${row.getAttribute("count")}` : null,
      `${round(row.getAttribute("average"), 0)} / ${round(row.getAttribute("p95"), 0)} ms`,
      number(row, "failures") > 0 ? `${row.getAttribute("failures")} failed` : null,
    ].filter(Boolean).join(" · ");
    line.append(track, element("span", "bar-value", value));
    box.append(line);
  }
  return box;
}

function footer(report) {
  const bottom = element("footer");
  const link = element("a", null, "Stampdrill");
  link.href = "https://stampdrill.com/";
  bottom.append(text("Written by "), link, text(` as report format ${report.getAttribute("version")}. The same file is valid XML: parse it, or open it.`));
  return bottom;
}

// MARK: small helpers

function element(name, className, textContent, nodes) {
  const node = document.createElement(name);
  if (className) node.className = className;
  if (textContent != null) node.textContent = textContent;
  if (nodes) node.append(...nodes);
  return node;
}

function paragraph(className, nodes) {
  const node = element("p", className);
  node.append(...nodes);
  return node;
}

function code(value) { return element("code", null, value); }
function text(value) { return document.createTextNode(value); }
function pill(state) { return element("span", "verdict " + state, state); }

/** The name of a data element without its prefix: stamp-request is a request. */
function kind(node) { return node.localName.slice("stamp-".length); }

function children(node, ...names) {
  const wanted = names.map((name) => "stamp-" + name);
  return Array.from(node.children).filter((child) => wanted.includes(child.localName));
}

function descendants(node, name) { return Array.from(node.querySelectorAll("stamp-" + name)); }

function child(node, name) { return children(node, name)[0] || null; }
function number(node, name) { return Number(node.getAttribute(name) || 0); }
function boolean(node, name) { return node.getAttribute(name) === "true"; }
function passed(node) { return boolean(node, "passed") ? "passed" : "failed"; }

function count(node, attribute, word) {
  const value = number(node, attribute);
  return `${value} ${word}${value === 1 ? "" : "s"}`;
}

function round(value, places) {
  const number = Number(value);
  if (!isFinite(number)) return String(value);
  return String(Math.round(number * 10 ** places) / 10 ** places);
}

function milliseconds(value) {
  const number = Number(value);
  return number >= 1000 ? `${(number / 1000).toFixed(2)} s` : `${number} ms`;
}

// MARK: registering

/* Last, because defining the elements draws the report there and then, and the
   page is built out of everything above. */
stylesheet();
define("stamp-report", StampReport);
define("stamp-plan", StampPlan);
define("stamp-load", StampLoad);
for (const data of DATA) define("stamp-" + data, class extends StampData {});
