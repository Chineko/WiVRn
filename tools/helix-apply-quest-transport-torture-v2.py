#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

BASE = "tools/helix-apply-quest-transport-torture.py"
PATH = "server/helix_synthetic_transport.cpp"
EXPECTED_BASE_BLOB = "6ced85f2081a062dbe9502e9b90f993fcaa2164e"


def blob(path: str) -> str:
    return subprocess.check_output(["git", "hash-object", path], text=True).strip()


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected one anchor, found {count}: {old[:100]!r}")
    return text.replace(old, new, 1)


def main() -> int:
    if blob(BASE) != EXPECTED_BASE_BLOB:
        raise RuntimeError("base torture transformer blob mismatch")

    subprocess.run([sys.executable, BASE], check=True)
    original = Path(PATH).read_text()
    text = original

    # Partial-loss cases intentionally preserve shard 0 so its expired view_info
    # suppresses automatic RTX. Full-frame loss is the only ordinary case that may
    # omit shard 0. This keeps the explicit RTX-rescue scenario isolated.
    text = replace_once(
        text,
        "\t\tconst uint16_t max_start = uint16_t(std::max<int>(1, shards_per_frame - missing));\n"
        "\t\tconst uint16_t start = uint16_t((event.id * 7) % max_start);",
        "\t\tconst uint16_t start = missing == shards_per_frame\n"
        "\t\t                               ? 0\n"
        "\t\t                               : uint16_t(1 + (event.id * 7) % (shards_per_frame - missing));",
    )

    text = replace_once(
        text,
        "\t\tconst uint16_t max_start = uint16_t(std::max<int>(1, shards_per_frame - missing));\n"
        "\t\tconst uint16_t start = uint16_t((r >> 16) % max_start);",
        "\t\tconst uint16_t start = missing == 0\n"
        "\t\t                               ? 0\n"
        "\t\t                               : uint16_t(1 + (r >> 16) % (shards_per_frame - missing));",
    )

    text = replace_once(
        text,
        "\t\t\tconst bool good = run_case(tx, connection, s, stream, frame[stream], missing, 0, false);",
        "\t\t\tconst uint16_t start = missing == shards_per_frame ? 0 : 1;\n"
        "\t\t\tconst bool good = run_case(tx, connection, s, stream, frame[stream], missing, start, false);",
    )

    Path(PATH).write_text(text)
    try:
        subprocess.run(["git", "diff", "--check", "--", PATH], check=True)
        for marker in (
            "missing == shards_per_frame ? 0 : 1",
            "explicit RTX-rescue scenario",
            "run_rtx_rescue_case",
        ):
            if marker not in text:
                raise RuntimeError(f"required v2 marker missing: {marker}")
    except Exception:
        Path(PATH).write_text(original)
        raise

    print("PASS: Quest transport torture v2 keeps ordinary partial losses RTX-free")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
