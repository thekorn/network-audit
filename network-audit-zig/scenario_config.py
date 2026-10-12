"""TOML/JSON Schema codec only; the Zig CLI owns validation and execution.

Use the existing Python runtime rather than introduce a separate TOML parser
and JSON Schema implementation for the experiment. No audit code is imported.
"""

import json
import sys
import tomllib
from pathlib import Path

from jsonschema import ValidationError, validate


def main():
    path, schema = map(Path, sys.argv[1:])
    try:
        with path.open("rb") as source:
            config = tomllib.load(source)
        validate(config, json.loads(schema.read_text()))
    except (OSError, tomllib.TOMLDecodeError, ValidationError) as error:
        print(f"Invalid scenario TOML/schema: {path}: {error}", file=sys.stderr)
        return 1
    print(json.dumps(config))
    return 0


if __name__ == "__main__":
    sys.exit(main())
