#!/usr/bin/env python3
from pathlib import Path

p = Path("server/encoder/video_encoder.cpp")
s = p.read_text()


def once(old: str, new: str, label: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"FAIL: {label} anchor count={n}")
    s = s.replace(old, new, 1)


once(
    "\tuint8_t next_case = 0;\n",
    "\tuint32_t next_case = 0;\n",
    "next_case width",
)

anchor = '''bool helix_encoded_torture_enabled()
{
\tstatic const bool enabled = [] {
\t\tconst char * value = std::getenv("HELIX_ENCODED_TORTURE");
\t\treturn value && std::string_view(value) == "1";
\t}();
\treturn enabled;
}
'''
addition = anchor + '''
uint32_t helix_encoded_torture_cycles()
{
\tstatic const uint32_t cycles = [] {
\t\tconst char * value = std::getenv("HELIX_ENCODED_TORTURE_CYCLES");
\t\tif (!value || !*value)
\t\t\treturn 1u;
\t\tchar * end = nullptr;
\t\tauto parsed = std::strtoul(value, &end, 10);
\t\tif (!end || *end != '\\0' || parsed == 0 || parsed > 1000)
\t\t\treturn 1u;
\t\treturn static_cast<uint32_t>(parsed);
\t}();
\treturn cycles;
}

uint64_t helix_encoded_torture_spacing_frames()
{
\tstatic const uint64_t spacing = []() -> uint64_t {
\t\tconst char * value = std::getenv("HELIX_ENCODED_TORTURE_SPACING_FRAMES");
\t\tif (!value || !*value)
\t\t\treturn 20;
\t\tchar * end = nullptr;
\t\tauto parsed = std::strtoull(value, &end, 10);
\t\tif (!end || *end != '\\0' || parsed < 20 || parsed > 1000000)
\t\t\treturn 20;
\t\treturn static_cast<uint64_t>(parsed);
\t}();
\treturn spacing;
}
'''
once(anchor, addition, "torture config helpers")

once(
    "\t\telse if (shard.shard_idx == 0 && !control && helix_encoded_torture.next_case < 3)\n",
    "\t\telse if (shard.shard_idx == 0 && !control && helix_encoded_torture.next_case < helix_encoded_torture_cycles() * 3u)\n",
    "injection cap",
)

once(
    "\t\t\tconst bool spacing_ok = helix_encoded_torture.last_injected_frame == 0 ||\n\t\t\t                        shard.frame_idx >= helix_encoded_torture.last_injected_frame + 20;\n",
    "\t\t\tconst bool spacing_ok = helix_encoded_torture.last_injected_frame == 0 ||\n\t\t\t                        shard.frame_idx >= helix_encoded_torture.last_injected_frame + helix_encoded_torture_spacing_frames();\n",
    "spacing",
)

once(
    "\t\t\t\tswitch (helix_encoded_torture.next_case)\n",
    "\t\t\t\tswitch (helix_encoded_torture.next_case % 3u)\n",
    "scenario cycling",
)

required = [
    'HELIX_ENCODED_TORTURE_CYCLES',
    'HELIX_ENCODED_TORTURE_SPACING_FRAMES',
    '[]() -> uint64_t',
    'next_case < helix_encoded_torture_cycles() * 3u',
    'helix_encoded_torture.last_injected_frame + helix_encoded_torture_spacing_frames()',
    'switch (helix_encoded_torture.next_case % 3u)',
    'candidate == helix_encoded_case::rtx8 ? 8 : candidate == helix_encoded_case::gap9 ? 9',
    'record.recovery_frame <= record.frame || record.recovery_frame - record.frame > 3',
]
for item in required:
    if item not in s:
        raise SystemExit(f"FAIL: sustained requirement missing: {item}")

for forbidden in [
    'next_case < 3)',
    'last_injected_frame + 20;',
    'switch (helix_encoded_torture.next_case)\\n',
    'return 20ull;',
]:
    if forbidden in s:
        raise SystemExit(f"FAIL: stale sustained anchor remains: {forbidden}")

p.write_text(s)
print("HELIX_ENCODED_SUSTAINED_TRANSFORM=PASS default_cycles=1 default_spacing=20")
