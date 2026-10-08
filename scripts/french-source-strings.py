#!/usr/bin/env python3
"""Gives every string of Void/Localizable.xcstrings its French value.

The keys are the French texts, but a system in a language other than French or English must get
English, so the app's development region is English (DEVELOPMENT_LANGUAGE = en). A French string
then needs its own entry: without one, the French interface would show the English translation.
Run it after adding strings (Xcode adds them to the catalog at build time):
    ./scripts/french-source-strings.py
"""
import json
import pathlib

catalog = pathlib.Path(__file__).resolve().parent.parent / "Void" / "Localizable.xcstrings"
data = json.loads(catalog.read_text(encoding="utf-8"))
added = 0
for key, entry in data["strings"].items():
    if entry.get("shouldTranslate") is False:
        continue
    localizations = entry.setdefault("localizations", {})
    if "fr" not in localizations:
        localizations["fr"] = {"stringUnit": {"state": "translated", "value": key}}
        added += 1
catalog.write_text(json.dumps(data, indent=2, separators=(",", " : "), ensure_ascii=False, sort_keys=True) + "\n",
                   encoding="utf-8")
print(f"{added} French value(s) added")
