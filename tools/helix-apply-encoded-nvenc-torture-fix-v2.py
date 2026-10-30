#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"error: {label} anchor count={count}")
    return text.replace(old, new, 1)

ve = Path("server/encoder/video_encoder.cpp")
text = ve.read_text()

text = replace_once(
    text,
    "} // namespace\n\nvideo_encoder::sender::sender() :\n",
    "} // namespace\n\nvoid helix_encoded_note_feedback_for_nvenc(const from_headset::feedback & feedback)\n{\n\thelix_encoded_note_feedback(feedback);\n}\n\nvideo_encoder::sender::sender() :\n",
    "NVENC torture feedback wrapper",
)

old_payload = "\tssize_t max_payload_size = (cnx->has_stream() and not control) ? to_headset::video_stream_data_shard::max_payload_size : std::numeric_limits<uint32_t>::max();\n"
new_payload = "\tconst bool helix_force_torture_fragmentation = encoded_case == helix_encoded_case::rtx8 || encoded_case == helix_encoded_case::gap9;\n\tssize_t max_payload_size = ((cnx->has_stream() || helix_force_torture_fragmentation) and not control)\n\t                                   ? to_headset::video_stream_data_shard::max_payload_size\n\t                                   : std::numeric_limits<uint32_t>::max();\n"
text = replace_once(text, old_payload, new_payload, "torture fragmentation")
ve.write_text(text)

nv = Path("server/encoder/video_encoder_nvenc.cpp")
text = nv.read_text()
text = replace_once(
    text,
    "namespace wivrn\n{\n\nstatic auto encode_guid(video_codec codec)\n",
    "namespace wivrn\n{\n\nvoid helix_encoded_note_feedback_for_nvenc(const from_headset::feedback & feedback);\n\nstatic auto encode_guid(video_codec codec)\n",
    "NVENC feedback declaration",
)
text = replace_once(
    text,
    "void video_encoder_nvenc::on_feedback(const from_headset::feedback & feedback)\n{\n\tauto & idr_handler = static_cast<default_idr_handler &>(*idr);\n",
    "void video_encoder_nvenc::on_feedback(const from_headset::feedback & feedback)\n{\n\thelix_encoded_note_feedback_for_nvenc(feedback);\n\tauto & idr_handler = static_cast<default_idr_handler &>(*idr);\n",
    "NVENC pre-return torture observation",
)
nv.write_text(text)
