#!/usr/bin/env python3
"""Render Active Priorities.md as a read-only Kanban board (one static HTML file).

Usage: board.py <Active Priorities.md> <out.html> [--full] [--embed] [--bg=<jpg>]
--full   wrap in a complete HTML document (served pages); without it the output is a
         body fragment (the claude.ai artifact preview adds its own skeleton).
--embed  transparent background, for the Homepage iframe.
--bg     background image, inlined as a data URI (standalone page only).
"""
import html
import re
import sys
from datetime import datetime, timezone
from urllib.parse import quote

COLUMNS = ["In progress", "Waiting", "To do", "Recurring", "Ideas"]
DONE_LIMIT = 8
PROJECTS = {"web-dev", "homelab", "personal", "meta"}
VAULT = "AI-Brain"


def inline(text):
    """Markdown inline subset -> safe HTML (bold, code, wikilinks)."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"<span class=\"wl\">\2</span>", out)
    out = re.sub(r"\[\[([^\]]+)\]\]", r"<span class=\"wl\">\1</span>", out)
    out = re.sub(r"~~([^~]+)~~", r"<s>\1</s>", out)
    return out


def parse_card(line):
    body = re.sub(r"^- \[[ x]\]\s*", "", line).strip()
    num = None
    im = re.match(r"#(\d+)\s+(.*)$", body)
    if im:
        num, body = int(im.group(1)), im.group(2)
    m = re.match(r"\*\*(.+?)\*\*\s*(.*)$", body)
    title, rest = (m.group(1), m.group(2)) if m else (body[:70], body)
    project = None
    pm = re.match(r"\(`([a-z-]+)`\)\s*(.*)$", rest)
    if pm and pm.group(1) in PROJECTS:
        project, rest = pm.group(1), pm.group(2)
    else:
        found = [p for p in re.findall(r"`([a-z-]+)`", rest) if p in PROJECTS]
        project = found[0] if found else None
    parked = bool(re.match(r"Parked\b", rest))
    rest = re.sub(r"^Parked\b[ .:]*", "", rest)
    note = None
    nm = re.search(r"→\s*\[\[([^\]|]+)(?:\|[^\]]+)?\]\]\s*$", rest)
    if nm:
        note = nm.group(1)
        rest = rest[: nm.start()].rstrip()
    rest = rest.lstrip(".:—- ").strip()
    trigger = None
    tm = re.search(r'Resume trigger: "([^"]+)"', rest)
    if tm:
        trigger = tm.group(1)
    return {"num": num, "title": title, "project": project, "parked": parked, "text": rest,
            "note": note, "trigger": trigger}


def parse(md):
    cols = {c: [] for c in COLUMNS}
    done = []
    current = None
    for line in md.split("\n"):
        h = re.match(r"^###\s+(.+?)\s*$", line)
        if h:
            current = h.group(1)
            continue
        if not line.startswith("- ["):
            continue
        if current in cols:
            cols[current].append(parse_card(line))
        elif current == "Completed Tasks" and len(done) < DONE_LIMIT:
            done.append(parse_card(line))
    return cols, done


def card_html(c, done=False):
    proj = c["project"] or "none"
    chips = []
    if c["num"] is not None:
        chips.append(f'<span class="chip id">#{c["num"]}</span>')
    chips.append(f'<span class="chip p-{proj}">{c["project"] or "other"}</span>')
    if c["parked"]:
        chips.append('<span class="chip parked">parked</span>')
    foot = ""
    if c["note"]:
        uri = f"obsidian://open?vault={quote(VAULT)}&file={quote(c['note'])}"
        foot = f'<a class="note" href="{uri}">{html.escape(c["note"])}</a>'
    text = inline(c["text"]) if c["text"] else ""
    detail = f'<p class="txt">{text}</p>' if text and not done else ""
    cls = "card done" if done else ("card parked-card" if c["parked"] else "card")
    return (f'<article class="{cls} pr-{proj}"><div class="chips">{"".join(chips)}</div>'
            f'<h3>{inline(c["title"])}</h3>{detail}{foot}</article>')


SHOW = 3


def col_html(key, name, count, cards, n):
    more = ""
    if n > SHOW:
        more = (f'<button class="more" type="button" aria-expanded="false" '
                f'data-all="Show all {n}" data-less="Show fewer">Show all {n}</button>')
    return (f'<section class="col c-{key}" data-col="{key}">'
            f'<button class="head" type="button" aria-expanded="true">'
            f'<h2>{name}</h2><span class="n">{count}</span><span class="chev" aria-hidden="true"></span></button>'
            f'<div class="body"><div class="cards">{cards}</div>{more}</div></section>')


def render(md, source_label, embed=False, bg_uri=""):
    cols, done = parse(md)
    now = datetime.now(timezone.utc).astimezone()
    counts = {c: len(v) for c, v in cols.items()}
    sections = []
    keys = {"In progress": "prog", "Waiting": "wait", "To do": "todo",
            "Recurring": "rec", "Ideas": "idea"}
    for c in COLUMNS:
        cards = "".join(card_html(x) for x in cols[c]) or '<p class="empty">Nothing here.</p>'
        sections.append(
            col_html(keys[c], c, counts[c], cards, len(cols[c])))
    dcards = "".join(card_html(x, done=True) for x in done)
    sections.append(col_html("done", "Recently done", len(done), dcards, len(done)))
    total_open = sum(counts.values())
    import hashlib
    version = hashlib.sha1("".join(sections).encode()).hexdigest()[:12]
    return TEMPLATE.format(
        mode="embed" if embed else "page", version=version,
        bg=f"url({bg_uri})" if bg_uri else "none",
        updated=now.strftime("%Y-%m-%d %H:%M"),
        total=total_open, prog=counts["In progress"], wait=counts["Waiting"],
        source=html.escape(source_label), columns="".join(sections))


TEMPLATE = open(__file__.rsplit("/",1)[0]+"/template.html", encoding="utf-8").read()

if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    md = open(src, encoding="utf-8").read()
    embed = "--embed" in sys.argv
    bg = ""
    for a in sys.argv[3:]:
        if a.startswith("--bg="):
            import base64
            bg = "data:image/jpeg;base64," + base64.b64encode(open(a[5:], "rb").read()).decode()
    full = "--full" in sys.argv
    page = render(md, "Active Priorities", embed=embed, bg_uri=bg)
    if embed:
        # A transparent iframe needs the same color-scheme as the page around it.
        page = page.replace("color-scheme: dark;", "color-scheme: normal;", 1)
    if full:
        page = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
                + page.replace("<!--BODY-->", "</head><body>") + "</body></html>")
    else:
        page = page.replace("<!--BODY-->", "")
    tmp = out + ".tmp"
    open(tmp, "w", encoding="utf-8").write(page)
    import os
    os.replace(tmp, out)
