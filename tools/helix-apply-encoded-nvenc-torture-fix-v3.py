#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"error: {label} anchor count={count}")
    return text.replace(old, new, 1)

ve = Path("server/encoder/video_encoder.cpp")
text = ve.read_text()

old = '''\t\tif (!record.feedback_seen || !record.recovered)\n\t\t\t++dirty;\n\t\telse if (record.scenario == helix_encoded_case::rtx8 && !record.sent_to_decoder)\n\t\t\t++dirty;\n\t\telse if (record.scenario != helix_encoded_case::rtx8 && !record.incomplete_seen)\n\t\t\t++dirty;\n\t\telse if (record.recovery_frame < record.frame || record.recovery_frame - record.frame > 3)\n\t\t\t++dirty;\n'''
new = '''\t\tif (!record.feedback_seen || !record.recovered)\n\t\t\t++dirty;\n\t\telse if (!record.incomplete_seen)\n\t\t\t++dirty;\n\t\telse if (record.recovery_frame <= record.frame || record.recovery_frame - record.frame > 3)\n\t\t\t++dirty;\n'''
text = replace_once(text, old, new, "encoded torture summary semantics")

ve.write_text(text)
