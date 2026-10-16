#!/usr/bin/env python3
"""Drops the `[Person]` member from the messages destination in App.app's
App Intents metadata, so Siri's runtime accepts Burrow as a message target.

Why (task 01a111bb, measured on iOS 27.0.1 on 2026-10-14): Xcode 27.0's
metadata processor REQUIRES the schema destination to be
`[Person] | MessagePerson | [MessagePerson]` and fails the build on anything
else. Siri's runtime (assistant_service) instead checks every member against
`MessagePerson | [MessagePerson] | Conversation` and rejects the whole union
("FlowToolValue failed conversion to/from TypedValue ... does not conform to
TypeConformance"), because `[Person]` matches none of them. So the Swift enum
keeps the case the compiler demands, and this script removes it from the
exported metadata. `[Person]` is the LAST member, so the indices of the
members Siri does use are unchanged. With the member removed, "Message Dalton
saying ..." reached MessagesSendIntent.perform() and sent.

Run by testflight.sh on the ARCHIVED App.app, before export re-signs it. It
can't be a build phase: the App target's script phases run before its
ExtractAppIntentsMetadata step, which rewrites the file (measured
2026-10-14). For a local device build, run it on the built App.app and
re-sign with codesign. Idempotent. Exits non-zero if the destination union
is missing, so a renamed type can't silently undo the fix. Delete this
script, and the `people` case, once an Xcode accepts the runtime's shape.

Usage: align_message_destination.py <path/to/App.app>
"""
import json
import os
import sys

UNION = "MessageDestinationCases"


def is_person_array(member):
    inner = member.get("array", {}).get("wrapper", {}).get("memberValueType", {})
    return "intents" in inner


def align(data):
    """Returns (unions found, members removed)."""
    found = removed = 0
    stack = [data]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            wrapper = node.get("wrapper")
            if isinstance(wrapper, dict) and wrapper.get("appEnumIdentifier") == UNION:
                found += 1
                members = wrapper["memberValueTypes"]
                kept = [m for m in members if not is_person_array(m)]
                removed += len(members) - len(kept)
                wrapper["memberValueTypes"] = kept
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return found, removed


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = os.path.join(sys.argv[1], "Metadata.appintents", "extract.actionsdata")
    with open(path) as f:
        data = json.load(f)
    found, removed = align(data)
    if found == 0:
        sys.exit(f"error: no {UNION} union in {path}; Siri messaging would break (task 01a111bb)")
    if removed:
        with open(path, "w") as f:
            json.dump(data, f)
    print(f"{UNION}: {found} parameter(s), removed {removed} [Person] member(s)")


if __name__ == "__main__":
    main()
