"""Build-time replacement of a measured baked helper and its startup digest pin."""
import argparse
import ast
import hashlib
import json
from pathlib import Path


def rebind(driver: Path, helper: Path, replacement: Path, receipt: Path,
           expected_driver: str, expected_helper: str, source_helper: Path | None = None) -> str:
    source = driver.read_bytes()
    if hashlib.sha256(source).hexdigest() != expected_driver:
        raise RuntimeError("driver digest mismatch")
    if hashlib.sha256(helper.read_bytes()).hexdigest() != expected_helper:
        raise RuntimeError("previous helper digest mismatch")
    if source_helper is not None and hashlib.sha256(source_helper.read_bytes()).hexdigest() != expected_helper:
        raise RuntimeError("source helper digest mismatch")
    text = source.decode()
    assignments = [n for n in ast.walk(ast.parse(text)) if isinstance(n, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == "HELPER_SHA256" for t in n.targets)]
    if (len(assignments) != 1 or not isinstance(assignments[0].value, ast.Constant)
            or assignments[0].value.value != expected_helper or text.count(expected_helper) != 1):
        raise RuntimeError("unexpected driver helper pin contract")
    updated_helper = replacement.read_bytes()
    updated_digest = hashlib.sha256(updated_helper).hexdigest()
    if updated_digest != json.loads(receipt.read_text())["helper_sha256"]:
        raise RuntimeError("replacement helper digest mismatch")
    ast.parse(updated_helper)
    updated_driver = text.replace(expected_helper, updated_digest).replace("(0.7.0)", "(0.9.2)")
    ast.parse(updated_driver)
    # This runs only while constructing a new image, never inside a live worker.
    helper.write_bytes(updated_helper)
    if source_helper is not None:
        source_helper.write_bytes(updated_helper)
    driver.write_text(updated_driver)
    return updated_digest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("driver", "helper", "replacement", "receipt"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--expected-driver", required=True)
    parser.add_argument("--expected-helper", required=True)
    parser.add_argument("--source-helper", type=Path)
    args = parser.parse_args()
    digest = rebind(args.driver, args.helper, args.replacement, args.receipt,
                    args.expected_driver, args.expected_helper, args.source_helper)
    print(json.dumps({"helper_sha256": digest, "serving_host_qualified": False}))
