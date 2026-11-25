#!/usr/bin/env python3
"""Deterministic vault lint for the nightly tidy run. Read-only: prints findings as JSON.

Checks (rules from VAULT-INDEX.md):
  frontmatter  - every .md note starts with YAML frontmatter holding valid status/project/type
  links        - a [[wikilink]] that resolves to nothing but closely matches an existing note name
                 (typo or rename left behind); other unresolved links are entity links and only counted
  index        - every note in a folder that has an index note (named after the folder, `NN - ` prefix
                 optional) is linked from that index,
                 and every subfolder index is linked from its parent folder's index
  cards        - Active Priorities: no duplicate card numbers, "Next number" above the highest used one
Usage: lint.py <vault>
"""
import difflib
import json
import re
import sys
from pathlib import Path

VALID = {
    "status": {"active", "completed", "parked", "idea", "archived"},
    "project": {"web-dev", "homelab", "personal", "meta"},
    "type": {"index", "reference", "guide", "plan", "log"},
}
SKIP_DIRS = {".git", ".obsidian", ".trash", ".claude"}
# config/code files kept in the vault for reinstalling; code files carry no frontmatter or wikilinks
SKIP_PREFIXES = ("06 - Resources/Configs/files/",)
LINK_RE = re.compile(r"!?\[\[([^\]|#^]*)(?:[#^][^\]|]*)?(?:\|[^\]]*)?\]\]")
FENCE_RE = re.compile(r"^(```|~~~).*?^\1", re.S | re.M)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")


def vault_files(root):
    for p in root.rglob("*"):
        rel = p.relative_to(root)
        if p.is_file() and not any(part in SKIP_DIRS for part in rel.parts) and not str(rel).startswith(SKIP_PREFIXES):
            yield p


def frontmatter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end < 0:
        return None
    fm = {}
    for line in text[4:end].splitlines():
        m = re.match(r"^([A-Za-z_-]+):\s*(.*?)\s*$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip("'\"")
    return fm


def strip_code(text):
    return INLINE_CODE_RE.sub("", FENCE_RE.sub("", text))


def main():
    root = Path(sys.argv[1]).expanduser().resolve()
    files = list(vault_files(root))
    notes = [p for p in files if p.suffix == ".md"]
    names = {p.stem.lower() for p in notes} | {p.name.lower() for p in files}
    # path-style links ([[folder/note]], [[Jobs/Code Review]]) resolve by any trailing part of the path
    for p in notes:
        parts = p.relative_to(root).with_suffix("").parts
        names |= {"/".join(parts[i:]).lower() for i in range(len(parts))}
    stems = sorted({p.stem for p in notes})
    texts = {p: p.read_text(encoding="utf-8", errors="replace") for p in notes}

    fm_issues, link_issues, index_issues = [], [], []
    unresolved_count = [0]
    for p, text in sorted(texts.items()):
        rel = str(p.relative_to(root))
        fm = frontmatter(text)
        if fm is None:
            fm_issues.append({"note": rel, "problem": "no frontmatter"})
        else:
            for key, ok in VALID.items():
                val = fm.get(key)
                if val is None:
                    fm_issues.append({"note": rel, "problem": f"missing {key}"})
                elif val not in ok:
                    fm_issues.append({"note": rel, "problem": f"invalid {key}: {val}"})
        unresolved = sorted({t.strip() for t in LINK_RE.findall(strip_code(text))
                             if t.strip() and t.strip().lower() not in names})
        for target in unresolved:
            # Entity links with no note yet ([[Canva]]) are allowed by the vault rules. Only a target that
            # closely matches an existing note looks like a typo or a rename left behind.
            close = difflib.get_close_matches(target, stems, n=1, cutoff=0.8)
            if close:
                link_issues.append({"note": rel, "link": target, "did_you_mean": close[0]})
            else:
                unresolved_count[0] += 1

    def linked_from(index_path):
        return {t.strip().split("/")[-1].lower() for t in LINK_RE.findall(texts[index_path])}

    def folder_index(folder):
        """The folder's index note: `type: index`, named after the folder with or without its `NN - ` prefix."""
        if folder == root:
            return None
        wanted = {folder.name.lower(), re.sub(r"^\d+\s*-\s*", "", folder.name).lower()}
        for p in texts:
            if p.parent == folder and p.stem.lower() in wanted:
                return p
        return None

    for folder in sorted({p.parent for p in notes}):
        index = folder_index(folder)
        if index is None:
            continue
        links = linked_from(index)
        missing = sorted(p.stem for p in notes
                         if p.parent == folder and p != index and p.stem.lower() not in links)
        if missing:
            index_issues.append({"index": str(index.relative_to(root)), "missing": missing, "kind": "notes"})
        parent_index = folder_index(folder.parent)
        if parent_index and index.stem.lower() not in linked_from(parent_index) \
                and folder.name.lower() not in linked_from(parent_index):
            index_issues.append({"index": str(parent_index.relative_to(root)),
                                 "missing": [index.stem], "kind": "subfolder index"})

    # Active Priorities card numbers: no duplicates among open cards, "Next number" above every used number
    card_issues = []
    board = root / "Active Priorities.md"
    if board in texts:
        nums = [int(n) for n in re.findall(r"^- \[[ x]\] #(\d+)\b", texts[board], re.M)]
        dups = sorted({n for n in nums if nums.count(n) > 1})
        if dups:
            card_issues.append({"problem": "duplicate card numbers", "numbers": dups})
        m = re.search(r"\*\*Next number: (\d+)\*\*", texts[board])
        if m and nums and int(m.group(1)) <= max(nums):
            card_issues.append({"problem": f"Next number {m.group(1)} is not above the highest used card number {max(nums)}"})

    json.dump({"frontmatter": fm_issues, "card_numbers": card_issues, "likely_broken_links": link_issues, "folder_index": index_issues,
               "unresolved_entity_links": unresolved_count[0]},
              sys.stdout, indent=1, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
