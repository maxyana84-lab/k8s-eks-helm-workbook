#!/usr/bin/env python3
"""Validate every eksctl ClusterConfig of the workbook against the JSON schema of eksctl itself.

Usage: eksctl utils schema > /tmp/eksctl-schema.json
       scripts/validate-eksctl.py /tmp/eksctl-schema.json 07-eks/*.yaml
"""
import json
import sys

import yaml
from jsonschema import Draft7Validator


def main() -> int:
    schema = json.load(open(sys.argv[1]))
    validator = Draft7Validator(schema)
    checked = failed = 0
    for path in sys.argv[2:]:
        for doc in yaml.safe_load_all(open(path)):
            if not isinstance(doc, dict) or doc.get("kind") != "ClusterConfig":
                continue
            checked += 1
            errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
            for e in errors:
                failed += 1
                where = "/".join(str(p) for p in e.path) or "(root)"
                print(f"{path}: {where}: {e.message}")
            if not errors:
                print(f"{path}: ClusterConfig is valid")
    if checked == 0:
        print("no ClusterConfig found")
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
