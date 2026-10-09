#!/usr/bin/env python3
"""Fails when an app extension declares an iOS 27 assistant-schema intent.

Siri's planner refuses a schema tool that more than one bundle in the app
declares ("Multiple flow tools found for tool id", ToolDiscoveryError
Code=4), so messages.*, phone.startCall and reminders.createReminder must
live in App.app's Metadata.appintents ONLY (task 01a111bb). Run against a
built or installed App.app; also run by the App target's post-build phase.

Usage: check_extension_schema_intents.py <path/to/App.app>
"""
import glob
import json
import os
import sys


def schema_actions(metadata_dir):
    path = os.path.join(metadata_dir, "extract.actionsdata")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        actions = json.load(f).get("actions", {})
    found = []
    for name, action in sorted(actions.items()):
        for schema in action.get("assistantDefinedSchemas") or []:
            found.append(f"{name} ({schema.get('domain')}.{schema.get('name')})")
    return found


def main(app):
    if not os.path.isdir(app):
        print(f"error: no app bundle at {app}", file=sys.stderr)
        return 2
    print(f"App.app: {len(schema_actions(os.path.join(app, 'Metadata.appintents')))} schema intents")
    bad = 0
    for meta in sorted(glob.glob(os.path.join(app, "PlugIns", "*.appex", "Metadata.appintents"))):
        ext = os.path.basename(os.path.dirname(meta))
        found = schema_actions(meta)
        print(f"{ext}: {len(found)} schema intents")
        for line in found:
            print(f"error: {ext} declares schema intent {line}; schema intents belong to the App target only", file=sys.stderr)
        bad += len(found)
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
