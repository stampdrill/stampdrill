<?xml version="1.0" encoding="UTF-8"?>
<!--
  Turns a Stampdrill test report into a page.

  A report written by "stamp test" with the stamp-xml option names this file in
  its processing instruction, so the same file a build server parses is the one a
  person opens. Browsers only apply a stylesheet served from the same place as the
  report, so to read a report from your own server, keep a copy of this file beside
  it and point the stamp-xsl option at it.

  Stampdrill report format 0.1. Copyright 2026 Siamand Maroufi.
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can
  obtain one at https://mozilla.org/MPL/2.0/.

  The source is at https://github.com/stampdrill/stampdrill/tree/main/report:
  one file, no scripts, no tracking, nothing fetched from anywhere.
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html" encoding="UTF-8" indent="yes"
            doctype-system="about:legacy-compat"/>

<!-- A duration, as a person reads it. -->
<xsl:template name="ms">
  <xsl:param name="value"/>
  <xsl:choose>
    <xsl:when test="$value &gt;= 1000"><xsl:value-of select="format-number($value div 1000, '0.00')"/> s</xsl:when>
    <xsl:otherwise><xsl:value-of select="$value"/> ms</xsl:otherwise>
  </xsl:choose>
</xsl:template>

<xsl:template name="verdict">
  <xsl:param name="passed"/>
  <xsl:choose>
    <xsl:when test="$passed = 'true'">passed</xsl:when>
    <xsl:otherwise>failed</xsl:otherwise>
  </xsl:choose>
</xsl:template>

<xsl:template match="/report">
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Stampdrill test report</title>
<style>
:root {
  color-scheme: light dark;
  --ink: #17181c; --dim: #5d6270; --faint: #8a8f9c; --line: #e4e5ea;
  --page: #ffffff; --panel: #f6f6f8; --accent: #e85a2e;
  --ok: #1f9d55; --bad: #d63031; --ok-soft: rgba(31,157,85,.12); --bad-soft: rgba(214,48,49,.1);
}
@media (prefers-color-scheme: dark) {
  :root {
    --ink: #eceef3; --dim: #a3a9b7; --faint: #767c8a; --line: #272a32;
    --page: #101114; --panel: #17191e; --accent: #f8734a;
    --ok: #4ad07f; --bad: #ff6b6b; --ok-soft: rgba(74,208,127,.14); --bad-soft: rgba(255,107,107,.13);
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--page); color: var(--ink);
  font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 64rem; margin: 0 auto; padding: 2.5rem 1.5rem 4rem; }
h1 { font-size: 1.6rem; letter-spacing: -.02em; margin: 0 0 .4rem; }
h2 { font-size: 1.1rem; margin: 0; letter-spacing: -.01em; }
.meta { color: var(--faint); font-size: .88rem; margin: 0 0 1.75rem; }
.meta code { color: var(--dim); }
.verdict {
  display: inline-block; border-radius: 999px; padding: .15rem .7rem; margin-right: .5rem;
  font-size: .8rem; font-weight: 650; text-transform: uppercase; letter-spacing: .05em; vertical-align: 2px;
}
.passed > .verdict, .verdict.passed { background: var(--ok-soft); color: var(--ok); }
.failed > .verdict, .verdict.failed { background: var(--bad-soft); color: var(--bad); }
.totals { display: flex; flex-wrap: wrap; gap: .5rem 2rem; margin: 0 0 2.5rem; padding: 1rem 1.2rem; border: 1px solid var(--line); border-radius: 14px; background: var(--panel); }
.totals div { min-width: 5.5rem; }
.totals dt { font-size: .74rem; text-transform: uppercase; letter-spacing: .06em; color: var(--faint); font-weight: 650; }
.totals dd { margin: .1rem 0 0; font-size: 1.3rem; font-variant-numeric: tabular-nums; }
.totals dd.bad { color: var(--bad); }
.plan { border: 1px solid var(--line); border-radius: 14px; padding: 1.1rem 1.25rem; margin: 0 0 1.25rem; }
.plan.failed { border-color: color-mix(in srgb, var(--bad) 45%, var(--line)); }
.plan > header { display: flex; flex-wrap: wrap; align-items: baseline; gap: .5rem; }
.file { color: var(--faint); font-size: .85rem; }
.counts { color: var(--dim); font-size: .88rem; margin: .35rem 0 .5rem; }
details { border-top: 1px solid var(--line); }
summary { cursor: pointer; display: flex; align-items: center; gap: .55rem; padding: .55rem 0; font-weight: 600; }
summary::-webkit-details-marker { display: none; }
summary::before { content: "›"; color: var(--faint); font-size: 1.1rem; line-height: 1; transition: transform .12s; }
details[open] > summary::before { transform: rotate(90deg); }
summary .time { margin-left: auto; font-weight: 400; color: var(--faint); font-size: .85rem; font-variant-numeric: tabular-nums; }
.dot { width: .5rem; height: .5rem; border-radius: 50%; background: var(--ok); flex: none; }
.failed > summary .dot, li.failed > .dot { background: var(--bad); }
.dims { color: var(--faint); font-size: .8rem; font-weight: 400; }
ul { list-style: none; margin: .2rem 0 .8rem; padding-left: 1.15rem; }
li { padding: .12rem 0; }
li::before { font-weight: 700; margin-right: .45rem; }
li.passed::before { content: "✓"; color: var(--ok); }
li.failed::before { content: "✗"; color: var(--bad); }
li.note::before { content: "·"; color: var(--faint); }
li.note { color: var(--dim); }
code { font: .83rem/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
.status { color: var(--faint); font-size: .83rem; margin-left: .35rem; font-variant-numeric: tabular-nums; }
.message { color: var(--bad); font-size: .85rem; white-space: pre-wrap; }
.step { font-weight: 650; }
table { width: 100%; border-collapse: collapse; margin-top: .75rem; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: .35rem .6rem; border-bottom: 1px solid var(--line); font-size: .88rem; }
th { color: var(--faint); font-weight: 600; font-size: .74rem; text-transform: uppercase; letter-spacing: .05em; }
td:not(:first-child), th:not(:first-child) { text-align: right; }
.section-title { margin: 1.1rem 0 .2rem; font-size: .72rem; text-transform: uppercase; letter-spacing: .06em; color: var(--faint); font-weight: 650; }
.metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(6rem, 1fr)); gap: .6rem 1rem; margin: .9rem 0 1.1rem; }
.metrics dt { font-size: .72rem; text-transform: uppercase; letter-spacing: .06em; color: var(--faint); font-weight: 650; }
.metrics dd { margin: .1rem 0 0; font-size: 1.15rem; font-variant-numeric: tabular-nums; }
.metrics dd.bad { color: var(--bad); }
.charts { display: grid; gap: .8rem; grid-template-columns: repeat(auto-fit, minmax(15rem, 1fr)); margin: .4rem 0 1rem; }
.chart { border: 1px solid var(--line); border-radius: 10px; padding: .6rem .7rem .4rem; }
.chart h3 { margin: 0 0 .1rem; font-size: .72rem; text-transform: uppercase; letter-spacing: .06em; color: var(--faint); font-weight: 650; }
.chart .peak { font-size: .8rem; color: var(--dim); font-variant-numeric: tabular-nums; }
.chart svg { display: block; width: 100%; height: 92px; }
.chart-scale { display: flex; justify-content: space-between; margin: .25rem 0 0; color: var(--faint); font-size: .72rem; font-variant-numeric: tabular-nums; }
.chart .grid { stroke: var(--line); stroke-width: 1; }
.chart .axis { fill: var(--faint); font-size: 10px; font-family: inherit; }
.bars { margin: .4rem 0 .6rem; }
.bar-row { display: grid; grid-template-columns: minmax(5rem, 11rem) 1fr auto; gap: .6rem; align-items: center; padding: .18rem 0; font-size: .86rem; }
.bar-track { background: var(--panel); border-radius: 4px; height: .55rem; position: relative; overflow: hidden; }
.bar { position: absolute; inset: 0 auto 0 0; background: var(--accent); border-radius: 4px; min-width: 2px; }
.bar.second { background: color-mix(in srgb, var(--accent) 35%, transparent); }
.bar-value { color: var(--dim); font-variant-numeric: tabular-nums; font-size: .82rem; }
.lanes { margin: .5rem 0 .2rem; }
.lane { display: grid; grid-template-columns: 4.5rem 1fr; gap: .6rem; align-items: center; padding: .12rem 0; font-size: .82rem; }
.lane-name { color: var(--faint); font-variant-numeric: tabular-nums; }
.lane-track { position: relative; height: .62rem; background: var(--panel); border-radius: 4px; }
.lane-bar { position: absolute; top: 0; bottom: 0; background: var(--ok); border-radius: 4px; min-width: 3px; }
.lane-bar.failed { background: var(--bad); }
.lane-scale { display: flex; justify-content: space-between; color: var(--faint); font-size: .74rem; margin: .2rem 0 .6rem 5.1rem; font-variant-numeric: tabular-nums; }
.pill { display: inline-block; border-radius: 999px; padding: .05rem .5rem; font-size: .74rem; font-weight: 650; }
.pill.passed { background: var(--ok-soft); color: var(--ok); }
.pill.failed { background: var(--bad-soft); color: var(--bad); }
footer { margin-top: 2.5rem; color: var(--faint); font-size: .83rem; }
footer a { color: var(--accent); }
</style>
</head>
<body>
<div class="wrap">
  <h1>
    <span class="verdict"><xsl:attribute name="class">verdict <xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
      <xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template>
    </span>
    Stampdrill test report
  </h1>
  <p class="meta">
    <xsl:value-of select="@startedAt"/> · <code><xsl:value-of select="@generator"/></code>
  </p>

  <dl class="totals">
    <xsl:if test="summary/@plans &gt; 0">
      <div><dt>Plans</dt><dd><xsl:value-of select="summary/@plans"/></dd></div>
      <div><dt>Iterations</dt><dd><xsl:value-of select="summary/@iterations"/></dd></div>
    </xsl:if>
    <xsl:if test="summary/@loads &gt; 0">
      <div><dt>Load tests</dt><dd><xsl:value-of select="summary/@loads"/></dd></div>
    </xsl:if>
    <div><dt>Requests</dt><dd><xsl:value-of select="summary/@requests"/></dd></div>
    <div><dt>Checks</dt><dd><xsl:value-of select="summary/@checks"/></dd></div>
    <div><dt>Checks failed</dt>
      <dd><xsl:if test="summary/@checksFailed &gt; 0"><xsl:attribute name="class">bad</xsl:attribute></xsl:if>
        <xsl:value-of select="summary/@checksFailed"/></dd></div>
    <div><dt>Time</dt><dd><xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template></dd></div>
  </dl>

  <xsl:apply-templates select="plan|load"/>

  <footer>
    Written by <a href="https://stampdrill.com/">Stampdrill</a> as report format
    <xsl:text> </xsl:text><xsl:value-of select="@version"/>. The same file is valid XML: parse it, or open it.
  </footer>
</div>
</body>
</html>
</xsl:template>

<xsl:template match="plan">
  <section>
    <xsl:attribute name="class">plan <xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <header>
      <h2><xsl:value-of select="@name"/></h2>
      <span class="file"><xsl:value-of select="@file"/></span>
    </header>
    <p class="counts">
      <xsl:value-of select="@iterations"/> iteration<xsl:if test="@iterations != 1">s</xsl:if>
      · <xsl:value-of select="@requests"/> request<xsl:if test="@requests != 1">s</xsl:if>
      · <xsl:value-of select="@checks"/> check<xsl:if test="@checks != 1">s</xsl:if>
      <xsl:if test="@checksFailed &gt; 0">, <xsl:value-of select="@checksFailed"/> failed</xsl:if>
      · <xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template>
    </p>
    <xsl:apply-templates select="iteration"/>
    <xsl:apply-templates select="timings"/>
  </section>
</xsl:template>

<xsl:template match="iteration">
  <details>
    <xsl:attribute name="class"><xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <xsl:if test="@passed = 'false'"><xsl:attribute name="open">open</xsl:attribute></xsl:if>
    <summary>
      <span class="dot"/>
      <xsl:value-of select="@label"/>
      <xsl:variable name="dimensions">
        <xsl:for-each select="dimension">
          <xsl:if test="position() &gt; 1">, </xsl:if>
          <xsl:value-of select="@name"/>=<xsl:value-of select="@value"/>
        </xsl:for-each>
      </xsl:variable>
      <!-- The label is often the dimensions themselves; saying it twice helps nobody. -->
      <xsl:if test="dimension and normalize-space($dimensions) != normalize-space(@label)">
        <span class="dims"><xsl:value-of select="$dimensions"/></span>
      </xsl:if>
      <span class="time"><xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template></span>
    </summary>
    <ul><xsl:apply-templates select="step|concurrently|request|expect|print|failure"/></ul>
  </details>
</xsl:template>

<xsl:template match="step">
  <li>
    <xsl:attribute name="class"><xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <span class="step"><xsl:value-of select="@title"/></span>
    <xsl:if test="@attempts &gt; 1"><span class="status">after <xsl:value-of select="@attempts"/> attempts</span></xsl:if>
    <span class="status"><xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template></span>
    <ul><xsl:apply-templates select="step|concurrently|request|expect|print|failure"/></ul>
  </li>
</xsl:template>

<xsl:template match="request">
  <li>
    <xsl:attribute name="class"><xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <code><xsl:value-of select="@method"/><xsl:text> </xsl:text><xsl:value-of select="@name"/></code>
    <xsl:if test="@status">
      <span class="status"><xsl:value-of select="@status"/> · <xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template></span>
    </xsl:if>
    <xsl:if test="@error"><div class="message"><xsl:value-of select="@error"/></div></xsl:if>
    <xsl:if test="check[@passed='false']">
      <ul><xsl:apply-templates select="check[@passed='false']"/></ul>
    </xsl:if>
  </li>
</xsl:template>

<xsl:template match="check|expect">
  <li>
    <xsl:attribute name="class"><xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <code><xsl:if test="name() = 'expect'">expect </xsl:if><xsl:value-of select="@source"/></code>
    <xsl:if test="@message"><div class="message"><xsl:value-of select="@message"/></div></xsl:if>
  </li>
</xsl:template>

<xsl:template match="print">
  <li class="note"><code><xsl:value-of select="."/></code></li>
</xsl:template>

<xsl:template match="failure">
  <li class="failed">
    <xsl:value-of select="."/>
    <span class="status">line <xsl:value-of select="@line"/></span>
  </li>
</xsl:template>

<xsl:template match="timings">
  <h3 class="section-title">Average and p95, by request</h3>
  <xsl:call-template name="bars"><xsl:with-param name="rows" select="timing"/></xsl:call-template>
</xsl:template>

<!--
  Charts, drawn from the numbers in the report. XSLT 1.0 has arithmetic and
  sorting, which is all a line or a bar needs, so the page carries no script.
-->

<!-- The largest value of one attribute across a set of elements, never zero. -->
<xsl:template name="peak">
  <xsl:param name="rows"/>
  <xsl:param name="field"/>
  <xsl:variable name="top">
    <xsl:for-each select="$rows">
      <xsl:sort select="@*[name() = $field]" data-type="number" order="descending"/>
      <xsl:if test="position() = 1"><xsl:value-of select="@*[name() = $field]"/></xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:choose>
    <xsl:when test="number($top) &gt; 0"><xsl:value-of select="$top"/></xsl:when>
    <xsl:otherwise>1</xsl:otherwise>
  </xsl:choose>
</xsl:template>

<!-- One measurement a second, as a filled line. -->
<xsl:template name="chart">
  <xsl:param name="rows"/>
  <xsl:param name="field"/>
  <xsl:param name="title"/>
  <xsl:param name="unit" select="''"/>
  <xsl:param name="tone" select="'var(--accent)'"/>
  <xsl:variable name="max">
    <xsl:call-template name="peak">
      <xsl:with-param name="rows" select="$rows"/>
      <xsl:with-param name="field" select="$field"/>
    </xsl:call-template>
  </xsl:variable>
  <xsl:variable name="count" select="count($rows)"/>
  <xsl:variable name="step" select="600 div (($count - 1) + ($count = 1))"/>
  <div class="chart">
    <h3><xsl:value-of select="$title"/></h3>
    <p class="peak">peak <xsl:value-of select="format-number(number($max), '#.##')"/><xsl:value-of select="$unit"/></p>
    <svg viewBox="0 0 600 140" preserveAspectRatio="none" role="img">
      <xsl:attribute name="aria-label"><xsl:value-of select="$title"/>, peaking at <xsl:value-of select="$max"/><xsl:value-of select="$unit"/></xsl:attribute>
      <line class="grid" x1="0" y1="20" x2="600" y2="20" vector-effect="non-scaling-stroke"/>
      <line class="grid" x1="0" y1="75" x2="600" y2="75" vector-effect="non-scaling-stroke"/>
      <line class="grid" x1="0" y1="130" x2="600" y2="130" vector-effect="non-scaling-stroke"/>
      <polygon opacity="0.14">
        <xsl:attribute name="fill"><xsl:value-of select="$tone"/></xsl:attribute>
        <xsl:attribute name="points">
          <xsl:text>0,130 </xsl:text>
          <xsl:for-each select="$rows">
            <xsl:value-of select="($step * (position() - 1))"/>
            <xsl:text>,</xsl:text>
            <xsl:value-of select="130 - (number(@*[name() = $field]) div number($max)) * 110"/>
            <xsl:text> </xsl:text>
          </xsl:for-each>
          <xsl:value-of select="$step * ($count - 1)"/><xsl:text>,130</xsl:text>
        </xsl:attribute>
      </polygon>
      <polyline fill="none" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke">
        <xsl:attribute name="stroke"><xsl:value-of select="$tone"/></xsl:attribute>
        <xsl:attribute name="points">
          <xsl:for-each select="$rows">
            <xsl:value-of select="($step * (position() - 1))"/>
            <xsl:text>,</xsl:text>
            <xsl:value-of select="130 - (number(@*[name() = $field]) div number($max)) * 110"/>
            <xsl:text> </xsl:text>
          </xsl:for-each>
        </xsl:attribute>
      </polyline>
    </svg>
    <p class="chart-scale"><span>0s</span><span><xsl:value-of select="$rows[last()]/@at"/>s</span></p>
  </div>
</xsl:template>

<!-- A bar per request: the darker bar is the average, the lighter one p95. -->
<xsl:template name="bars">
  <xsl:param name="rows"/>
  <xsl:variable name="max">
    <xsl:call-template name="peak">
      <xsl:with-param name="rows" select="$rows"/>
      <xsl:with-param name="field" select="'p95'"/>
    </xsl:call-template>
  </xsl:variable>
  <div class="bars">
    <xsl:for-each select="$rows">
      <div class="bar-row">
        <code><xsl:value-of select="@name"/></code>
        <div class="bar-track">
          <span class="bar second">
            <xsl:attribute name="style">width: <xsl:value-of select="number(@p95) div number($max) * 100"/>%</xsl:attribute>
            <xsl:attribute name="title">p95 <xsl:value-of select="@p95"/> ms</xsl:attribute>
          </span>
          <span class="bar">
            <xsl:attribute name="style">width: <xsl:value-of select="number(@average) div number($max) * 100"/>%</xsl:attribute>
            <xsl:attribute name="title">average <xsl:value-of select="@average"/> ms</xsl:attribute>
          </span>
        </div>
        <span class="bar-value">
          <xsl:if test="@count">×<xsl:value-of select="@count"/> · </xsl:if>
          <xsl:value-of select="format-number(number(@average), '#')"/> / <xsl:value-of select="format-number(number(@p95), '#')"/> ms
          <xsl:if test="@failures &gt; 0"> · <xsl:value-of select="@failures"/> failed</xsl:if>
        </span>
      </div>
    </xsl:for-each>
  </div>
</xsl:template>

<xsl:template match="load">
  <section>
    <xsl:attribute name="class">plan <xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <header>
      <h2><xsl:value-of select="@name"/></h2>
      <span class="file"><xsl:value-of select="@file"/></span>
      <span class="pill">
        <xsl:attribute name="class">pill <xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
        load test
      </span>
    </header>
    <p class="counts">
      <xsl:value-of select="@users"/> users · <xsl:value-of select="@iterations"/> iterations ·
      <xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template>
    </p>

    <dl class="metrics">
      <div><dt>Requests</dt><dd><xsl:value-of select="metrics/@requests"/></dd></div>
      <div><dt>Per second</dt><dd><xsl:value-of select="format-number(metrics/@rps, '#.#')"/></dd></div>
      <div><dt>Errors</dt>
        <dd><xsl:if test="metrics/@failed &gt; 0"><xsl:attribute name="class">bad</xsl:attribute></xsl:if>
          <xsl:value-of select="format-number(metrics/@errorRate * 100, '#.##')"/>%</dd></div>
      <div><dt>p50</dt><dd><xsl:value-of select="format-number(metrics/@p50, '#')"/> ms</dd></div>
      <div><dt>p95</dt><dd><xsl:value-of select="format-number(metrics/@p95, '#')"/> ms</dd></div>
      <div><dt>p99</dt><dd><xsl:value-of select="format-number(metrics/@p99, '#')"/> ms</dd></div>
      <div><dt>Max</dt><dd><xsl:value-of select="format-number(metrics/@max, '#')"/> ms</dd></div>
      <div><dt>Checks</dt>
        <dd><xsl:if test="metrics/@checksFailed &gt; 0"><xsl:attribute name="class">bad</xsl:attribute></xsl:if>
          <xsl:value-of select="metrics/@checks - metrics/@checksFailed"/>/<xsl:value-of select="metrics/@checks"/></dd></div>
    </dl>

    <xsl:if test="series/second">
      <div class="charts">
        <xsl:call-template name="chart">
          <xsl:with-param name="rows" select="series/second"/>
          <xsl:with-param name="field" select="'requests'"/>
          <xsl:with-param name="title" select="'Requests a second'"/>
        </xsl:call-template>
        <xsl:call-template name="chart">
          <xsl:with-param name="rows" select="series/second"/>
          <xsl:with-param name="field" select="'p95'"/>
          <xsl:with-param name="title" select="'p95 latency'"/>
          <xsl:with-param name="unit" select="' ms'"/>
          <xsl:with-param name="tone" select="'var(--bad)'"/>
        </xsl:call-template>
        <xsl:call-template name="chart">
          <xsl:with-param name="rows" select="series/second"/>
          <xsl:with-param name="field" select="'users'"/>
          <xsl:with-param name="title" select="'Active users'"/>
          <xsl:with-param name="tone" select="'var(--ok)'"/>
        </xsl:call-template>
        <xsl:if test="series/second[@errors &gt; 0]">
          <xsl:call-template name="chart">
            <xsl:with-param name="rows" select="series/second"/>
            <xsl:with-param name="field" select="'errors'"/>
            <xsl:with-param name="title" select="'Errors a second'"/>
            <xsl:with-param name="tone" select="'var(--bad)'"/>
          </xsl:call-template>
        </xsl:if>
      </div>
    </xsl:if>

    <xsl:if test="requests/request">
      <h3 class="section-title">Average and p95, by request</h3>
      <xsl:call-template name="bars"><xsl:with-param name="rows" select="requests/request"/></xsl:call-template>
    </xsl:if>

    <xsl:if test="thresholds/threshold">
      <table>
        <thead><tr><th>Threshold</th><th>Measured</th><th>Verdict</th></tr></thead>
        <tbody>
          <xsl:for-each select="thresholds/threshold">
            <tr>
              <td><code><xsl:value-of select="@source"/></code></td>
              <td>
                <xsl:choose>
                  <xsl:when test="@metric = 'errors' or @metric = 'checks'">
                    <xsl:value-of select="format-number(@measured * 100, '#.##')"/>%
                  </xsl:when>
                  <xsl:otherwise><xsl:value-of select="format-number(@measured, '#.##')"/></xsl:otherwise>
                </xsl:choose>
              </td>
              <td>
                <span>
                  <xsl:attribute name="class">pill <xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
                  <xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template>
                </span>
              </td>
            </tr>
          </xsl:for-each>
        </tbody>
      </table>
    </xsl:if>

    <xsl:if test="failures/failure">
      <h3 class="section-title">What went wrong</h3>
      <ul>
        <xsl:for-each select="failures/failure">
          <li class="failed"><xsl:value-of select="."/><span class="status">× <xsl:value-of select="@count"/></span></li>
        </xsl:for-each>
      </ul>
    </xsl:if>
  </section>
</xsl:template>

<!-- A `concurrently` block: who started when, on one clock. -->
<xsl:template match="concurrently">
  <li>
    <xsl:attribute name="class"><xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <span class="step"><xsl:value-of select="@title"/></span>
    <span class="status"><xsl:value-of select="@actors"/> actors at once · <xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template></span>
    <xsl:variable name="span">
      <xsl:choose>
        <xsl:when test="number(@ms) &gt; 0"><xsl:value-of select="@ms"/></xsl:when>
        <xsl:otherwise>1</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="first" select="descendant::request[1]/@at"/>
    <div class="lanes">
      <xsl:for-each select="actor">
        <div class="lane">
          <span class="lane-name">actor <xsl:value-of select="@index"/></span>
          <div class="lane-track">
            <xsl:for-each select="descendant::request">
              <span>
                <xsl:attribute name="class">lane-bar<xsl:if test="@passed = 'false'"> failed</xsl:if></xsl:attribute>
                <xsl:attribute name="style">left: <xsl:value-of select="(number(@at) - number($first)) div number($span) * 100"/>%; width: <xsl:value-of select="number(@ms) div number($span) * 100"/>%</xsl:attribute>
                <xsl:attribute name="title"><xsl:value-of select="@name"/>: started <xsl:value-of select="number(@at) - number($first)"/> ms in, took <xsl:value-of select="@ms"/> ms</xsl:attribute>
              </span>
            </xsl:for-each>
          </div>
        </div>
      </xsl:for-each>
      <div class="lane-scale"><span>0 ms</span><span><xsl:value-of select="@ms"/> ms</span></div>
    </div>
    <ul><xsl:apply-templates select="actor"/></ul>
  </li>
</xsl:template>

<xsl:template match="actor">
  <li>
    <xsl:attribute name="class"><xsl:call-template name="verdict"><xsl:with-param name="passed" select="@passed"/></xsl:call-template></xsl:attribute>
    <span class="step">actor <xsl:value-of select="@index"/></span>
    <xsl:if test="number(@ms) &gt; 0">
      <span class="status"><xsl:call-template name="ms"><xsl:with-param name="value" select="@ms"/></xsl:call-template></span>
    </xsl:if>
    <ul><xsl:apply-templates select="step|request|expect|print|failure|concurrently"/></ul>
  </li>
</xsl:template>

</xsl:stylesheet>
