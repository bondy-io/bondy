#!/usr/bin/env python3
"""Fleet-bench HTML report generator.

Parses the artifacts a fleet-scale run leaves behind and emits ONE
self-contained HTML file (inline CSS, inline SVG — no external
dependencies, safe to mail or archive):

  - k6 load-generator summaries:   run_s<N>.log / s<N>_lg.log
  - memory samplers (optional):    s<N>_mem*.csv  (timestamp,machine,total_kb,used_kb)
                                   ab_s<N>_ets.csv (timestamp,machine,ets_bytes)
  - AE-health sampler (optional):  s<N>_ae*.log   (ets_bytes parsed per line)

Usage:
  python3 harness/fleet-scale/report.py --data-dir <dir> --out report.html

Run annotations (what changed between runs) live in NOTES below — edit
as the series grows.
"""
import argparse
import csv
import html
import os
import re
import sys
from datetime import datetime, timezone

NOTES = {
    "s3": "Fleet-OOM fix chain validated: ETS peak 776 MB during load, "
          "drained continuously post-load (was 5.6–6.9 GB pinned).",
    "s5": "Session-open (WELCOME) diagnosis / harness-fix arc.",
    "s6": "Session-open (WELCOME) diagnosis / harness-fix arc.",
    "s7": "Session-open (WELCOME) diagnosis / harness-fix arc.",
    "s8": "AE auth-fence arc (db.aae.fence.max_lag + retryable abort).",
    "s9": "AE auth-fence arc — fence fix verified (+27% throughput).",
    "s10": "Delivery-arc baseline — flow-pool PUBLISH serialization "
           "still in place (delivery med 3m13s, 88% shed).",
    "s11": "Instrumented diagnosis run (flow occupancy / shed samplers).",
    "s12": "Inline PUBLISH/YIELD routing (flow pool ingress-only): "
           "events ×15.8, zero sheds.",
    "s13": "Relay ingress singleton eliminated (direct-to-flow-worker): "
           "delivery med 25 ms.",
    "s14": "HELLO admission control (bondy_regulator_load busy-ABORT): "
           "welcome med ≈500 ms, +56% admitted publishers.",
    "s15": "Final AE state (data-loss triad + live-event door): "
           "1 frontier-gap verdict / 0 re-bootstraps cluster-wide, "
           "full post-load drain, identical frontiers.",
    "s16": "Rerun incl. AE-health prometheus export + ptrie CAS "
           "telemetry. Latencies in the s15 class. SURFACED A NEW BUG: "
           "one node lost 2 pages of registry/4's own MST root "
           "(servable=false) → aae_root=undefined → peers' rounds fail "
           "benignly root_unservable forever → no complete rounds → no "
           "gap verdicts → recovery deadlock: 86.3k events never "
           "compact, real frontier divergence. Under investigation.",
}

DUR_RE = re.compile(r"^(?:(\d+)m)?(\d+(?:\.\d+)?)(ms|s|µs|us)?$")


def to_ms(tok):
    """k6 duration token -> float ms. '2m14s' '1.04s' '206.53ms' '0s' '85µs'."""
    m = DUR_RE.match(tok)
    if not m:
        return None
    mins, num, unit = m.groups()
    v = float(num)
    if unit in ("µs", "us"):
        v /= 1000.0
    elif unit == "ms" or unit is None and mins is None:
        pass
    elif unit == "s" or unit is None:
        v *= 1000.0
    if mins:
        v += int(mins) * 60_000.0
    return v


def fmt_ms(v):
    if v is None:
        return "—"
    if v >= 60_000:
        return f"{int(v // 60_000)}m{(v % 60_000) / 1000:.0f}s"
    if v >= 1000:
        return f"{v / 1000:.2f}s"
    return f"{v:.0f}ms"


def fmt_n(v):
    if v is None:
        return "—"
    if v >= 1_000_000:
        return f"{v / 1_000_000:.2f}M"
    if v >= 1_000:
        return f"{v / 1_000:.1f}k"
    return f"{v:.0f}"


METRIC_RE = re.compile(r"^\s*(wamp_\w+)\.*:?\s*(.*)$")
PAIR_RE = re.compile(r"(\S+?)=(\S+)")
COUNT_RE = re.compile(r"^(\d+)\s+([\d.]+)/s")
PCT_RE = re.compile(r"^([\d.]+)%\s+(\d+) out of (\d+)")
LGS_RE = re.compile(
    r"(\d+) LGs: 1 subscriber \((\d+) VUs\) \+ (\d+) publisher\(s\) "
    r"\((\d+) VUs each, (\d+) total\)"
)
RAMP_RE = re.compile(r"ramp=(\S+?) hold=(\S+?)[,)]")


def parse_metric_line(line):
    m = METRIC_RE.match(line)
    if not m:
        return None
    name, rest = m.groups()
    rest = rest.strip()
    out = {"name": name}
    cm = COUNT_RE.match(rest)
    pm = PCT_RE.match(rest)
    if cm:
        out["count"] = int(cm.group(1))
        out["rate"] = float(cm.group(2))
    elif pm:
        out["pct"] = float(pm.group(1))
        out["got"] = int(pm.group(2))
        out["want"] = int(pm.group(3))
    else:
        for k, v in PAIR_RE.findall(rest):
            ms = to_ms(v)
            if ms is not None:
                out[k] = ms
    return out


def parse_run(path):
    run = {
        "file": os.path.basename(path),
        "mtime": datetime.fromtimestamp(os.path.getmtime(path), timezone.utc),
        "params": {},
        "subscriber": {},
        "publishers": [],
    }
    section = None
    cur_pub = None
    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            lg = LGS_RE.search(line)
            if lg:
                run["params"].update(
                    lgs=int(lg.group(1)), sub_vus=int(lg.group(2)),
                    pub_lgs=int(lg.group(3)), pub_vus_each=int(lg.group(4)),
                    pub_vus_total=int(lg.group(5)),
                )
            rm = RAMP_RE.search(line)
            if rm:
                run["params"].update(ramp=rm.group(1), hold=rm.group(2))
            if "SUBSCRIBER" in line and "====" in line:
                section = "sub"
                continue
            if "PUBLISHERS" in line and "====" in line:
                section = "pub"
                continue
            if section == "pub" and line.startswith("--- PUB"):
                cur_pub = {}
                run["publishers"].append(cur_pub)
                continue
            met = parse_metric_line(line)
            if met:
                tgt = run["subscriber"] if section == "sub" else cur_pub
                if tgt is not None:
                    tgt[met.pop("name")] = met
    return run


def agg_pub(run):
    tot = {"publishes": 0, "rate": 0.0, "errors": 0, "aborts": 0}
    for p in run["publishers"]:
        s = p.get("wamp_publishes_sent", {})
        tot["publishes"] += s.get("count", 0)
        tot["rate"] += s.get("rate", 0.0)
        tot["errors"] += p.get("wamp_errors", {}).get("count", 0)
        tot["aborts"] += p.get("wamp_aborts", {}).get("count", 0)
    return tot


def read_mem_csvs(paths):
    """[(ts, machine, used_bytes)] from mem CSVs (used_kb col)."""
    rows = []
    for p in paths:
        with open(p) as f:
            for r in csv.DictReader(f):
                try:
                    rows.append((
                        r["timestamp"], r["machine_id"],
                        int(r["mem_used_kb"]) * 1024,
                    ))
                except (KeyError, ValueError):
                    continue
    return sorted(rows)


def read_ets_csvs(paths):
    rows = []
    for p in paths:
        with open(p) as f:
            for r in csv.DictReader(f):
                try:
                    rows.append(
                        (r["timestamp"], r["machine_id"], int(r["ets_bytes"]))
                    )
                except (KeyError, ValueError):
                    continue
    return sorted(rows)


AE_RE = re.compile(r"^(\S+) (\S+) .*?ets_bytes, (\d+)")


def read_ae_logs(paths):
    rows = []
    for p in paths:
        with open(p, errors="replace") as f:
            for line in f:
                m = AE_RE.match(line)
                if m:
                    rows.append((m.group(1), m.group(2), int(m.group(3))))
    return sorted(rows)


def svg_chart(series, title, unit_gb=True, w=1040, h=260):
    """series: {machine: [(ts, value_bytes)]} -> inline SVG line chart."""
    pad_l, pad_r, pad_t, pad_b = 64, 12, 28, 34
    all_pts = [p for pts in series.values() for p in pts]
    if not all_pts:
        return ""
    ts_all = sorted({t for t, _ in all_pts})
    t_idx = {t: i for i, t in enumerate(ts_all)}
    vmax = max(v for _, v in all_pts) * 1.08 or 1
    iw, ih = w - pad_l - pad_r, h - pad_t - pad_b
    nmax = max(len(ts_all) - 1, 1)
    colors = ["#0e7490", "#b45309", "#6d28d9", "#15803d", "#b91c1c",
              "#1d4ed8"]
    out = [
        f'<svg viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="{html.escape(title)}">',
        f'<text x="{pad_l}" y="16" class="ct">{html.escape(title)}</text>',
    ]
    for i in range(5):
        y = pad_t + ih * i / 4
        v = vmax * (1 - i / 4)
        lbl = f"{v / 1024 ** 3:.1f} GB" if unit_gb else fmt_n(v)
        out.append(
            f'<line x1="{pad_l}" y1="{y:.1f}" x2="{w - pad_r}" y2="{y:.1f}" '
            'class="grid"/>'
            f'<text x="{pad_l - 6}" y="{y + 4:.1f}" class="al">{lbl}</text>'
        )
    for ti in (0, len(ts_all) // 2, len(ts_all) - 1):
        if 0 <= ti < len(ts_all):
            x = pad_l + iw * ti / nmax
            lbl = ts_all[ti][11:19] if len(ts_all[ti]) >= 19 else ts_all[ti]
            out.append(
                f'<text x="{x:.1f}" y="{h - 12}" class="al am">{lbl}</text>'
            )
    for i, (machine, pts) in enumerate(sorted(series.items())):
        c = colors[i % len(colors)]
        path = " ".join(
            f"{'M' if j == 0 else 'L'}"
            f"{pad_l + iw * t_idx[t] / nmax:.1f},"
            f"{pad_t + ih * (1 - v / vmax):.1f}"
            for j, (t, v) in enumerate(pts)
        )
        out.append(f'<path d="{path}" fill="none" stroke="{c}" '
                   'stroke-width="1.8"/>')
        out.append(
            f'<text x="{pad_l + 8 + i * 170}" y="{pad_t - 6}" class="al" '
            f'fill="{c}">▬ {html.escape(machine[:12])}</text>'
        )
    out.append("</svg>")
    return "".join(out)


CSS = """
:root{--bg:#fafaf9;--ink:#1c1e21;--mut:#6b7280;--line:#e4e2df;
--acc:#0e7490;--card:#ffffff;--good:#15803d;--warn:#b45309;--bad:#b91c1c}
@media (prefers-color-scheme: dark){:root{--bg:#16181d;--ink:#e7e5e4;
--mut:#9ca3af;--line:#2b2e35;--acc:#38bdf8;--card:#1d2026}}
:root[data-theme="dark"]{--bg:#16181d;--ink:#e7e5e4;--mut:#9ca3af;
--line:#2b2e35;--acc:#38bdf8;--card:#1d2026}
:root[data-theme="light"]{--bg:#fafaf9;--ink:#1c1e21;--mut:#6b7280;
--line:#e4e2df;--acc:#0e7490;--card:#ffffff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1100px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:26px;margin:0 0 4px;text-wrap:balance}
h2{font-size:17px;margin:40px 0 10px;color:var(--acc);
text-transform:uppercase;letter-spacing:.06em}
.sub{color:var(--mut);margin:0 0 6px}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:8px;
background:var(--card)}
th,td{padding:7px 10px;text-align:right;border-top:1px solid var(--line);
white-space:nowrap}
th{color:var(--mut);font-weight:600;border-top:0;font-size:12.5px;
text-transform:uppercase;letter-spacing:.04em}
td:first-child,th:first-child{text-align:left}
tr.best td{color:var(--good);font-weight:600}
.note{color:var(--mut);font-size:13px}
details{border:1px solid var(--line);border-radius:8px;margin:10px 0;
background:var(--card)}
summary{cursor:pointer;padding:10px 14px;font-weight:600}
summary .note{font-weight:400;margin-left:8px}
details>div{padding:0 14px 14px}
svg{width:100%;height:auto;display:block;background:var(--card);
border:1px solid var(--line);border-radius:8px;margin:10px 0}
.ct{font:600 13px ui-sans-serif,system-ui;fill:var(--ink)}
.al{font:11px ui-sans-serif,system-ui;fill:var(--mut);text-anchor:end}
.am{text-anchor:middle}
.grid{stroke:var(--line);stroke-width:1}
.kpi{display:flex;flex-wrap:wrap;gap:10px;margin:14px 0}
.kpi div{background:var(--card);border:1px solid var(--line);
border-radius:8px;padding:10px 14px;min-width:150px}
.kpi b{display:block;font-size:20px;font-variant-numeric:tabular-nums}
.kpi span{color:var(--mut);font-size:12.5px}
"""


def build_html(runs, charts, data_dir):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    latest = runs[-1] if runs else None
    parts = [
        "<meta charset='utf-8'>",
        "<meta name='viewport' content='width=device-width,initial-scale=1'>",
        "<title>Bondy fleet bench — s-series report</title>",
        f"<style>{CSS}</style>",
        "<main>",
        "<h1>Bondy fleet bench — s-series report</h1>",
        f"<p class='sub'>Generated {now} from "
        f"<code>{html.escape(data_dir)}</code> · target: bondy-fleet-1, "
        "3× Fly performance-8x (16 GB) · load: k6 fleet-scale "
        "harness (anonymous WS, exact-match pub/sub).</p>",
    ]
    if latest:
        s = latest["subscriber"]
        d = s.get("wamp_delivery_latency_ms", {})
        wl = s.get("wamp_welcome_latency_ms", {})
        ap = agg_pub(latest)
        parts.append("<div class='kpi'>")
        for big, small in [
            (fmt_ms(d.get("med")), f"delivery med · {latest['label']}"),
            (fmt_ms(d.get("p(95)")), "delivery p95"),
            (fmt_ms(wl.get("med")), "welcome med"),
            (f"{fmt_n(ap['publishes'])}", "publishes sent"),
            (f"{ap['rate']:,.0f}/s", "aggregate publish rate"),
        ]:
            parts.append(f"<div><b>{big}</b><span>{small}</span></div>")
        parts.append("</div>")

    parts.append("<h2>Run comparison</h2>")
    parts.append(
        "<p class='note'>One row per run, oldest first. Latency columns are "
        "the subscriber-side k6 metrics; publishes/aborts are summed across "
        "publisher load generators. The best delivery-median row is "
        "highlighted. NOTE: from s14 on, the aborts column is dominated by "
        "HELLO admission-control refusals — cheap retryable ABORTs that "
        "protect the data plane — so a large value there is the load "
        "regulator working, not client failures.</p>"
    )
    parts.append("<div class='tw'><table><thead><tr>"
                 "<th>run</th><th>date</th><th>pub VUs</th>"
                 "<th>publishes</th><th>rate/s</th>"
                 "<th>delivery med</th><th>p95</th>"
                 "<th>welcome med</th><th>p95</th>"
                 "<th>subscribe avg</th><th>aborts</th>"
                 "</tr></thead><tbody>")
    best = None
    for r in runs:
        med = r["subscriber"].get("wamp_delivery_latency_ms", {}).get("med")
        if med is not None and (best is None or med < best[1]):
            best = (r["label"], med)
    for r in runs:
        s = r["subscriber"]
        d = s.get("wamp_delivery_latency_ms", {})
        wl = s.get("wamp_welcome_latency_ms", {})
        sl = s.get("wamp_subscribe_latency_ms", {})
        ap = agg_pub(r)
        cls = " class='best'" if best and r["label"] == best[0] else ""
        parts.append(
            f"<tr{cls}><td>{r['label']}</td>"
            f"<td>{r['mtime'].strftime('%m-%d %H:%M')}</td>"
            f"<td>{fmt_n(r['params'].get('pub_vus_total'))}</td>"
            f"<td>{fmt_n(ap['publishes'])}</td>"
            f"<td>{ap['rate']:,.0f}</td>"
            f"<td>{fmt_ms(d.get('med'))}</td>"
            f"<td>{fmt_ms(d.get('p(95)'))}</td>"
            f"<td>{fmt_ms(wl.get('med'))}</td>"
            f"<td>{fmt_ms(wl.get('p(95)'))}</td>"
            f"<td>{fmt_ms(sl.get('avg'))}</td>"
            f"<td>{fmt_n(ap['aborts'])}</td></tr>"
        )
    parts.append("</tbody></table></div>")

    if charts:
        parts.append("<h2>Resource charts</h2>")
        parts.extend(charts)

    parts.append("<h2>Per-run detail</h2>")
    for r in reversed(runs):
        note = NOTES.get(r["label"], "")
        p = r["params"]
        prm = ""
        if p.get("pub_vus_total"):
            prm = (f"{p.get('lgs', '?')} LGs · "
                   f"{fmt_n(p['pub_vus_total'])} pub + "
                   f"{fmt_n(p.get('sub_vus'))} sub VUs · "
                   f"ramp {p.get('ramp', '?')} / hold {p.get('hold', '?')}")
        parts.append(
            f"<details><summary>{r['label']} "
            f"<span class='note'>{r['mtime'].strftime('%Y-%m-%d %H:%M')} "
            f"· {html.escape(prm)}"
            f"{(' · ' + html.escape(note)) if note else ''}</span>"
            "</summary><div>"
        )
        parts.append("<div class='tw'><table><thead><tr><th>metric</th>"
                     "<th>avg</th><th>med</th><th>p95</th><th>p99</th>"
                     "<th>max</th></tr></thead><tbody>")
        for name in ("wamp_delivery_latency_ms", "wamp_welcome_latency_ms",
                     "wamp_subscribe_latency_ms", "wamp_subscribe_burst_ms"):
            m = r["subscriber"].get(name)
            if not m:
                continue
            parts.append(
                f"<tr><td>{name.replace('wamp_', '').replace('_ms', '')}"
                "</td>" + "".join(
                    f"<td>{fmt_ms(m.get(k))}</td>"
                    for k in ("avg", "med", "p(95)", "p(99)", "max")
                ) + "</tr>"
            )
        ok = r["subscriber"].get("wamp_all_subscribed_ok", {})
        ap = agg_pub(r)
        parts.append("</tbody></table></div>")
        parts.append(
            f"<p class='note'>subscribed-ok {ok.get('pct', 0):.0f}% "
            f"({fmt_n(ok.get('got'))} of {fmt_n(ok.get('want'))}) · "
            f"publishers: {fmt_n(ap['publishes'])} sent at "
            f"{ap['rate']:,.0f}/s aggregate, {fmt_n(ap['errors'])} errors, "
            f"{fmt_n(ap['aborts'])} aborts "
            f"(admission refusals are counted as aborts from s14 on).</p>"
        )
        parts.append("</div></details>")

    parts.append(
        "<p class='note'>Self-contained report — no external assets. "
        "Generated by <code>harness/fleet-scale/report.py</code>; run "
        "annotations are maintained in its <code>NOTES</code> map.</p>"
    )
    parts.append("</main>")
    return "\n".join(parts)


def series_from_rows(rows):
    by = {}
    for ts, machine, v in rows:
        by.setdefault(machine, []).append((ts, v))
    return by


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    d = args.data_dir

    runs = []
    for f in sorted(os.listdir(d)):
        m = re.match(r"^(?:run_(s\d+)\.log|(s\d+)_lg\.log)$", f)
        if not m:
            continue
        label = m.group(1) or m.group(2)
        r = parse_run(os.path.join(d, f))
        if not r["subscriber"]:
            continue
        r["label"] = label
        runs.append(r)
    runs.sort(key=lambda r: int(r["label"][1:]))
    if not runs:
        sys.exit(f"no parseable run logs in {d}")

    charts = []
    ab_ets = [os.path.join(d, f) for f in sorted(os.listdir(d))
              if re.match(r"^ab_s\d+_ets\.csv$", f)]
    if ab_ets:
        for p in ab_ets:
            label = re.search(r"(s\d+)", os.path.basename(p)).group(1)
            rows = read_ets_csvs([p])
            if rows:
                charts.append(svg_chart(
                    series_from_rows(rows),
                    f"ETS bytes per node — run {label}"))
    labels = sorted(
        {re.match(r"^(s\d+)_(?:mem\S*\.csv|ae\S*\.log)$", f).group(1)
         for f in os.listdir(d)
         if re.match(r"^(s\d+)_(?:mem\S*\.csv|ae\S*\.log)$", f)},
        key=lambda s: int(s[1:]),
    )
    for label in labels:
        mem = [os.path.join(d, f) for f in sorted(os.listdir(d))
               if re.match(rf"^{label}_mem\S*\.csv$", f)]
        if mem:
            charts.append(svg_chart(
                series_from_rows(read_mem_csvs(mem)),
                f"Memory used per node — run {label} (load + drain)"))
        ae = [os.path.join(d, f) for f in sorted(os.listdir(d))
              if re.match(rf"^{label}_ae\S*\.log$", f)]
        if ae:
            rows = read_ae_logs(ae)
            if rows:
                charts.append(svg_chart(
                    series_from_rows(rows),
                    f"Erlang ETS bytes per node — run {label} "
                    "(load + drain)"))

    html_out = build_html(runs, charts, d)
    with open(args.out, "w") as f:
        f.write(html_out)
    print(f"wrote {args.out}: {len(runs)} runs, {len(charts)} charts")


if __name__ == "__main__":
    main()
