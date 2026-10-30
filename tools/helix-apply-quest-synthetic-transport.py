#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

EXPECTED = {
    "server/main.cpp": "af2f457d5c7399430105e39ad5175cfd6d8bf8c0",
    "server/CMakeLists.txt": "dcfc2117e95c7b69191b9b4afcf4507f845f25b8",
    "server/helix_synthetic_transport.cpp": "4e833ed349e6ad78e7409da9a866002e30e4ab00",
}


def blob(path: str) -> str:
    return subprocess.check_output(["git", "hash-object", path], text=True).strip()


def replace_once(text: str, old: str, new: str, path: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    for path, expected in EXPECTED.items():
        actual = blob(path)
        if actual != expected:
            raise RuntimeError(f"{path}: blob mismatch: expected {expected}, got {actual}")

    originals = {p: Path(p).read_text() for p in EXPECTED}
    updated = dict(originals)

    path = "server/CMakeLists.txt"
    updated[path] = replace_once(
        updated[path],
        "\t\t\tmain.cpp\n\t\t\tsleep_inhibitor.cpp",
        "\t\t\tmain.cpp\n\t\t\thelix_synthetic_transport.cpp\n\t\t\tsleep_inhibitor.cpp",
        path,
    )

    path = "server/main.cpp"
    updated[path] = replace_once(
        updated[path],
        '#include "application.h"\n#include "sleep_inhibitor.h"',
        '#include "application.h"\n#include "helix_synthetic_transport.h"\n#include "sleep_inhibitor.h"',
        path,
    )
    updated[path] = replace_once(
        updated[path],
        "#include <CLI/CLI.hpp>\n#include <avahi-glib/glib-watch.h>",
        "#include <CLI/CLI.hpp>\n#include <avahi-glib/glib-watch.h>\n#include <atomic>",
        path,
    )
    updated[path] = replace_once(
        updated[path],
        "std::optional<std::jthread> connection_thread;\n\nstd::unique_ptr<children_manager> children;",
        "std::optional<std::jthread> connection_thread;\nstd::optional<std::jthread> helix_synthetic_thread;\nbool helix_synthetic_transport_enabled = false;\nstd::atomic<int> helix_synthetic_result{-1};\n\nstd::unique_ptr<children_manager> children;",
        path,
    )

    old_success = '''\tconfiguration c;\n\tstart_server(c);\n\ttry\n\t{\n\t\tchildren->start_application(c.application);\n\t}\n\tcatch (std::exception & e)\n\t{\n\t\tstd::cerr << "Failed to start application: " << e.what() << std::endl;\n\t}\n\n\tdelay_next_try = default_delay_next_try;\n\n\tconnection.reset();\n\treturn G_SOURCE_REMOVE;'''
    new_success = '''\tdelay_next_try = default_delay_next_try;\n\n\tif (helix_synthetic_transport_enabled)\n\t{\n\t\tstd::cerr << "Helix synthetic transport mode: starting bounded receiver battery" << std::endl;\n\t\thelix_synthetic_thread.emplace([](std::stop_token stop_token) {\n\t\t\tint result = 1;\n\t\t\ttry\n\t\t\t{\n\t\t\t\tresult = wivrn::helix_synthetic_transport::run(*connection, stop_token);\n\t\t\t}\n\t\t\tcatch (const std::exception & e)\n\t\t\t{\n\t\t\t\tstd::cerr << "Helix synthetic transport failed: " << e.what() << std::endl;\n\t\t\t}\n\n\t\t\thelix_synthetic_result.store(result, std::memory_order_release);\n\t\t\tg_main_context_invoke(nullptr, [](void *) -> gboolean {\n\t\t\t\tconst int result = helix_synthetic_result.load(std::memory_order_acquire);\n\t\t\t\tstd::cerr << "HELIX_SYNTHETIC_TRANSPORT_EXIT result=" << result << std::endl;\n\t\t\t\tquitting_main_loop = true;\n\t\t\t\tg_main_loop_quit(main_loop);\n\t\t\t\treturn G_SOURCE_REMOVE;\n\t\t\t}, nullptr);\n\t\t});\n\t\treturn G_SOURCE_REMOVE;\n\t}\n\n\tconfiguration c;\n\tstart_server(c);\n\ttry\n\t{\n\t\tchildren->start_application(c.application);\n\t}\n\tcatch (std::exception & e)\n\t{\n\t\tstd::cerr << "Failed to start application: " << e.what() << std::endl;\n\t}\n\n\tconnection.reset();\n\treturn G_SOURCE_REMOVE;'''
    updated[path] = replace_once(updated[path], old_success, new_success, path)

    updated[path] = replace_once(
        updated[path],
        'auto no_encrypt = app.add_flag("--no-encrypt")->description("disable encryption")->group("Debug");',
        'auto no_encrypt = app.add_flag("--no-encrypt")->description("disable encryption")->group("Debug");\n\tauto helix_synthetic_transport = app.add_flag("--helix-synthetic-transport")->description("run bounded Helix Quest synthetic transport validation instead of starting Monado")->group("Debug");',
        path,
    )
    updated[path] = replace_once(
        updated[path],
        "\tdo_fork = not *no_fork;\n\tif (*no_encrypt)",
        "\tdo_fork = not *no_fork;\n\thelix_synthetic_transport_enabled = bool(*helix_synthetic_transport);\n\tif (helix_synthetic_transport_enabled)\n\t{\n\t\tif (*early_active_runtime)\n\t\t{\n\t\t\tstd::cerr << \"--helix-synthetic-transport is incompatible with --early-active-runtime\" << std::endl;\n\t\t\treturn 2;\n\t\t}\n\t\tdo_active_runtime = false;\n\t\tdo_fork = false;\n\t}\n\tif (*no_encrypt)",
        path,
    )
    updated[path] = replace_once(
        updated[path],
        "\t// Cleanup\n\tnotify_uninit();",
        "\t// Cleanup. Join the bounded synthetic worker before releasing its connection.\n\tif (helix_synthetic_thread)\n\t{\n\t\thelix_synthetic_thread->request_stop();\n\t\thelix_synthetic_thread.reset();\n\t}\n\tif (helix_synthetic_transport_enabled)\n\t\tconnection.reset();\n\n\tnotify_uninit();",
        path,
    )
    updated[path] = replace_once(
        updated[path],
        "\treturn wivrn_exit_code::success;\n}\n\nint main(int argc, char * argv[])",
        "\tif (helix_synthetic_transport_enabled)\n\t\treturn helix_synthetic_result.load(std::memory_order_acquire) == 0\n\t\t               ? int(wivrn_exit_code::success)\n\t\t               : int(wivrn_exit_code::unknown_error);\n\n\treturn wivrn_exit_code::success;\n}\n\nint main(int argc, char * argv[])",
        path,
    )

    path = "server/helix_synthetic_transport.cpp"
    updated[path] = replace_once(
        updated[path],
        '''\t// Warm-up establishes independent receiver packet-sequence state for both color streams.\n\tfor (uint8_t stream = 0; stream < 2; ++stream)\n\t{\n\t\tif (!run_case(tx, connection, s, stream, frame[stream], 0, 0, false))\n\t\t\t++s.catastrophic;\n\t\tframe[stream] += 2;\n\t}\n\n\tfor (const auto & event: recorded_events)''',
        '''\t// Warm-up establishes independent receiver packet-sequence state for both color streams.\n\tfor (uint8_t stream = 0; stream < 2; ++stream)\n\t{\n\t\tif (!run_case(tx, connection, s, stream, frame[stream], 0, 0, false))\n\t\t\t++s.catastrophic;\n\t\tframe[stream] += 2;\n\t}\n\n\t// Dominant historical failure class: the entire encoded frame disappears before\n\t// Quest wlan0. Exercise a literal 64/64-shard erasure on both production streams.\n\tfor (uint8_t stream = 0; stream < 2; ++stream)\n\t{\n\t\trun_case(tx, connection, s, stream, frame[stream], shards_per_frame, 0, false);\n\t\tframe[stream] += 2;\n\t}\n\n\tfor (const auto & event: recorded_events)''',
        path,
    )

    for path, text in updated.items():
        Path(path).write_text(text)

    try:
        subprocess.run(["git", "diff", "--check", "--", *EXPECTED.keys()], check=True)
        changed = set(subprocess.check_output(["git", "diff", "--name-only", "--", *EXPECTED.keys()], text=True).splitlines())
        if changed != set(EXPECTED):
            raise RuntimeError(f"unexpected changed paths: {sorted(changed)}")
        markers = {
            "server/CMakeLists.txt": ("helix_synthetic_transport.cpp",),
            "server/main.cpp": (
                "--helix-synthetic-transport",
                "helix_synthetic_transport::run",
                "HELIX_SYNTHETIC_TRANSPORT_EXIT",
                "helix_synthetic_thread->request_stop()",
                "helix_synthetic_result.store",
            ),
            "server/helix_synthetic_transport.cpp": (
                "HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY",
                "shards_per_frame, 0, false",
                "recorded_events",
            ),
        }
        for marker_path, required in markers.items():
            for marker in required:
                if marker not in updated[marker_path]:
                    raise RuntimeError(f"required marker missing from {marker_path}: {marker}")
    except Exception:
        for path, text in originals.items():
            Path(path).write_text(text)
        raise

    print("PASS: Quest synthetic transport server hook applied")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
