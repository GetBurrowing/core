"""Durable candidate ledger. Git ref CAS serializes concurrent observers."""
import datetime as dt
import json
import re

GAP_SECONDS = 5400  # hourly schedule with 30 minutes of delivery tolerance


def initial(candidate, mode):
    return {"version": 1, "candidate": candidate, "mode": mode,
            "first": None, "last": None, "hours": [], "failures": []}


def timestamp(now):
    if now.tzinfo is None:
        raise ValueError("UTC-aware observation time required")
    return now.astimezone(dt.UTC).isoformat()


def validate(state):
    if (not isinstance(state, dict) or set(state) != {"version", "candidate", "mode", "first", "last", "hours", "failures"}
            or state["version"] != 1 or not isinstance(state["candidate"], str)
            or not re.fullmatch(r"[0-9a-f]{40}", state["candidate"])
            or state["mode"] not in ("both", "canary")
            or not isinstance(state["hours"], list) or not isinstance(state["failures"], list)):
        raise ValueError("malformed candidate ledger")
    for field in ("first", "last"):
        value = state[field]
        if value is not None and (not isinstance(value, str) or dt.datetime.fromisoformat(value).utcoffset() != dt.timedelta(0)):
            raise ValueError("ledger timestamps must be exact UTC")
    if state["first"] and not state["last"]:
        raise ValueError("ledger lost last observation")
    for hour in state["hours"]:
        if not isinstance(hour, str):
            raise TypeError("malformed hour")
        dt.datetime.strptime(hour, "%Y%m%dT%HZ")
    if bool(state["hours"]) != bool(state["first"]):
        raise ValueError("ledger lost interval or hours")
    for failure in state["failures"]:
        if (not isinstance(failure, dict) or set(failure) != {"at", "reason"}
                or not isinstance(failure["reason"], str)
                or not isinstance(failure["at"], str)
                or dt.datetime.fromisoformat(failure["at"]).utcoffset() != dt.timedelta(0)):
            raise ValueError("malformed failure ledger")


def observe(state, candidate, mode, now, healthy, reason):
    validate(state)
    # Round-trip copies ensure callers never expose uncommitted success.
    result = json.loads(json.dumps(state))
    if (result.get("version") != 1 or result.get("candidate") != candidate
            or result.get("mode") != mode):
        raise ValueError("lost or incompatible candidate generation state")
    stamp = timestamp(now)
    last = dt.datetime.fromisoformat(result["last"]) if result["last"] else None
    if last and (now < last or (now - last).total_seconds() > GAP_SECONDS):
        healthy, reason = False, "clock reversal or missing observation gap"
    if not healthy:
        result["failures"].append({"at": stamp, "reason": reason})
    elif not result["failures"]:
        result["first"] = result["first"] or stamp
        hour = now.astimezone(dt.UTC).strftime("%Y%m%dT%HZ")
        if hour not in result["hours"]:
            result["hours"].append(hour)
    result["last"] = stamp
    return result


def complete(state, hours=24):
    validate(state)
    if state["failures"] or not state["first"] or not state["last"]:
        return False
    elapsed = (dt.datetime.fromisoformat(state["last"])
               - dt.datetime.fromisoformat(state["first"])).total_seconds()
    return elapsed >= max(24, hours) * 3600 and len(set(state["hours"])) >= hours
