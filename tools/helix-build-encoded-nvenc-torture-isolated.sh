#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || { echo "error: run from inside WiVRn checkout" >&2; exit 2; }
cd "${repo_root}"

base_commit="a97cf8add2c0e90954b45523dca3346fbb40e93d"
source_branch="helix-encoded-nvenc-torture"
version_prefix="helix-encoded"

for cmd in git python3 clang-format cmake ninja ar nm realpath grep find java sha256sum c++ dlopen true; do
    if [[ "${cmd}" == dlopen || "${cmd}" == true ]]; then continue; fi
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

git cat-file -e "${base_commit}^{commit}" 2>/dev/null || git fetch origin "${base_commit}"
git cat-file -e "${base_commit}^{commit}" 2>/dev/null || { echo "error: base commit unavailable" >&2; exit 2; }
if git ls-remote --exit-code --heads origin "${source_branch}" >/dev/null 2>&1; then
    echo "error: origin/${source_branch} already exists; classify existing state before rebuilding" >&2
    exit 2
fi

out="${HOME}/helix-encoded-nvenc-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'base_commit=%s\nsource_branch=%s\ncaller_head=%s\n' "$base_commit" "$source_branch" "$(git rev-parse HEAD)" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${base_commit}" >/dev/null
cd "${worktree}"
[[ "$(git rev-parse HEAD)" == "$base_commit" ]] || { echo "error: wrong isolated base" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated worktree dirty" >&2; exit 2; }

cat >"${out}/apply_encoded_torture.py" <<'PY'
from pathlib import Path

ve = Path("server/encoder/video_encoder.cpp")
text = ve.read_text()

if '#include <cstdio>\n' not in text:
    anchor = '#include <chrono>\n'
    if text.count(anchor) != 1:
        raise SystemExit('error: chrono include anchor not unique')
    text = text.replace(anchor, anchor + '#include <cstdio>\n#include <cstdlib>\n', 1)

registry = 'std::array<video_encoder *, 3> helix_rtx_encoder_registry{};\n'
if text.count(registry) != 1:
    raise SystemExit('error: RTX registry anchor not unique')
state_code = r'''

enum class helix_encoded_case : uint8_t
{
	none,
	rtx8,
	gap9,
	full_reference,
};

const char * helix_encoded_case_name(helix_encoded_case c)
{
	switch (c)
	{
		case helix_encoded_case::none: return "none";
		case helix_encoded_case::rtx8: return "rtx8";
		case helix_encoded_case::gap9: return "gap9";
		case helix_encoded_case::full_reference: return "full_reference";
	}
	return "unknown";
}

struct helix_encoded_record
{
	helix_encoded_case scenario = helix_encoded_case::none;
	uint64_t frame = 0;
	uint64_t encoded_bytes = 0;
	uint64_t dropped = 0;
	uint64_t total_shards = 0;
	bool feedback_seen = false;
	bool sent_to_decoder = false;
	bool incomplete_seen = false;
	bool recovered = false;
	uint64_t recovery_frame = 0;
};

struct helix_encoded_state
{
	std::mutex mutex;
	uint8_t next_case = 0;
	uint64_t last_injected_frame = 0;
	std::unordered_map<uint64_t, helix_encoded_record> records;
	std::optional<uint64_t> awaiting_recovery;
};

helix_encoded_state helix_encoded_torture;

bool helix_encoded_torture_enabled()
{
	static const bool enabled = [] {
		const char * value = std::getenv("HELIX_ENCODED_TORTURE");
		return value && std::string_view(value) == "1";
	}();
	return enabled;
}

void helix_encoded_note_feedback(const from_headset::feedback & feedback)
{
	if (!helix_encoded_torture_enabled() || feedback.stream_index != 0)
		return;

	std::scoped_lock lock(helix_encoded_torture.mutex);
	auto it = helix_encoded_torture.records.find(feedback.frame_index);
	if (it != helix_encoded_torture.records.end() && !it->second.feedback_seen)
	{
		auto & record = it->second;
		record.feedback_seen = true;
		record.sent_to_decoder = feedback.sent_to_decoder != 0;
		record.incomplete_seen = feedback.sent_to_decoder == 0;
		std::fprintf(stderr,
		             "HELIX_ENCODED_FEEDBACK scenario=%s stream=0 frame=%llu sent_to_decoder=%d\n",
		             helix_encoded_case_name(record.scenario),
		             static_cast<unsigned long long>(record.frame),
		             record.sent_to_decoder);
		std::fflush(stderr);
		if (record.sent_to_decoder)
		{
			record.recovered = true;
			record.recovery_frame = record.frame;
			std::fprintf(stderr,
			             "HELIX_ENCODED_RECOVERY scenario=%s stream=0 lost_frame=%llu recovered_frame=%llu delta=0 mode=same_frame\n",
			             helix_encoded_case_name(record.scenario),
			             static_cast<unsigned long long>(record.frame),
			             static_cast<unsigned long long>(record.frame));
			std::fflush(stderr);
		}
		else
		{
			helix_encoded_torture.awaiting_recovery = record.frame;
		}
	}

	if (feedback.sent_to_decoder && helix_encoded_torture.awaiting_recovery &&
	    feedback.frame_index > *helix_encoded_torture.awaiting_recovery)
	{
		auto lost = *helix_encoded_torture.awaiting_recovery;
		auto lost_it = helix_encoded_torture.records.find(lost);
		if (lost_it != helix_encoded_torture.records.end() && !lost_it->second.recovered)
		{
			auto & record = lost_it->second;
			record.recovered = true;
			record.recovery_frame = feedback.frame_index;
			std::fprintf(stderr,
			             "HELIX_ENCODED_RECOVERY scenario=%s stream=0 lost_frame=%llu recovered_frame=%llu delta=%llu mode=fresh_frame\n",
			             helix_encoded_case_name(record.scenario),
			             static_cast<unsigned long long>(lost),
			             static_cast<unsigned long long>(feedback.frame_index),
			             static_cast<unsigned long long>(feedback.frame_index - lost));
			std::fflush(stderr);
		}
		helix_encoded_torture.awaiting_recovery.reset();
	}
}

void helix_encoded_log_summary()
{
	if (!helix_encoded_torture_enabled())
		return;
	std::scoped_lock lock(helix_encoded_torture.mutex);
	uint64_t feedback = 0;
	uint64_t recovered = 0;
	uint64_t dirty = 0;
	for (const auto & [frame, record]: helix_encoded_torture.records)
	{
		feedback += record.feedback_seen;
		recovered += record.recovered;
		if (!record.feedback_seen || !record.recovered)
			++dirty;
		else if (record.scenario == helix_encoded_case::rtx8 && !record.sent_to_decoder)
			++dirty;
		else if (record.scenario != helix_encoded_case::rtx8 && !record.incomplete_seen)
			++dirty;
		else if (record.recovery_frame < record.frame || record.recovery_frame - record.frame > 3)
			++dirty;
	}
	std::fprintf(stderr,
	             "HELIX_ENCODED_TORTURE_SUMMARY injected=%zu feedback=%llu recovered=%llu dirty=%llu next_case=%u\n",
	             helix_encoded_torture.records.size(),
	             static_cast<unsigned long long>(feedback),
	             static_cast<unsigned long long>(recovered),
	             static_cast<unsigned long long>(dirty),
	             helix_encoded_torture.next_case);
	std::fflush(stderr);
}
'''
text = text.replace(registry, registry + state_code, 1)

old_feedback = '''void video_encoder::on_feedback(const from_headset::feedback & feedback)\n{\n\tassert(feedback.stream_index == stream_idx);\n\tidr->on_feedback(feedback);\n}\n'''
new_feedback = '''void video_encoder::on_feedback(const from_headset::feedback & feedback)\n{\n\tassert(feedback.stream_index == stream_idx);\n\thelix_encoded_note_feedback(feedback);\n\tidr->on_feedback(feedback);\n}\n'''
if text.count(old_feedback) != 1:
    raise SystemExit('error: on_feedback anchor not unique')
text = text.replace(old_feedback, new_feedback, 1)

old_dtor_tail = '''\thelix_log_pacing_summary(this);\n}\n\nbool video_encoder::request_retransmission'''
new_dtor_tail = '''\thelix_log_pacing_summary(this);\n\tif (stream_idx == 0)\n\t\thelix_encoded_log_summary();\n}\n\nbool video_encoder::request_retransmission'''
if text.count(old_dtor_tail) != 1:
    raise SystemExit('error: destructor tail anchor not unique')
text = text.replace(old_dtor_tail, new_dtor_tail, 1)

send_start = '''void video_encoder::SendData(std::span<uint8_t> data, bool end_of_frame, bool control)\n{\n\tstd::lock_guard lock(mutex);\n'''
if text.count(send_start) != 1:
    raise SystemExit('error: SendData start anchor not unique')
send_insert = r'''void video_encoder::SendData(std::span<uint8_t> data, bool end_of_frame, bool control)
{
	std::lock_guard lock(mutex);

	helix_encoded_case encoded_case = helix_encoded_case::none;
	if (helix_encoded_torture_enabled() && stream_idx == 0)
	{
		std::scoped_lock torture_lock(helix_encoded_torture.mutex);
		if (auto existing = helix_encoded_torture.records.find(shard.frame_idx); existing != helix_encoded_torture.records.end())
		{
			encoded_case = existing->second.scenario;
		}
		else if (shard.shard_idx == 0 && !control && helix_encoded_torture.next_case < 3)
		{
			auto * handler = dynamic_cast<default_idr_handler *>(idr.get());
			const bool reference_p = handler && !handler->is_non_ref_frame(shard.frame_idx);
			const bool previous_done = helix_encoded_torture.next_case == 0 ||
			                           (helix_encoded_torture.records.contains(helix_encoded_torture.last_injected_frame) &&
			                            helix_encoded_torture.records.at(helix_encoded_torture.last_injected_frame).recovered);
			const bool spacing_ok = helix_encoded_torture.last_injected_frame == 0 ||
			                        shard.frame_idx >= helix_encoded_torture.last_injected_frame + 20;
			if (reference_p && previous_done && spacing_ok && shard.frame_idx >= 30)
			{
				helix_encoded_case candidate = helix_encoded_case::none;
				switch (helix_encoded_torture.next_case)
				{
					case 0: candidate = helix_encoded_case::rtx8; break;
					case 1: candidate = helix_encoded_case::gap9; break;
					case 2: candidate = helix_encoded_case::full_reference; break;
				}
				const size_t minimum_bytes = candidate == helix_encoded_case::full_reference
				                                     ? 1
				                                     : 16 * to_headset::video_stream_data_shard::max_payload_size;
				if (data.size() >= minimum_bytes)
				{
					encoded_case = candidate;
					helix_encoded_torture.records.emplace(
					        shard.frame_idx,
					        helix_encoded_record{
					                .scenario = candidate,
					                .frame = shard.frame_idx,
					                .encoded_bytes = data.size(),
					        });
					helix_encoded_torture.last_injected_frame = shard.frame_idx;
					++helix_encoded_torture.next_case;
					const unsigned drop_count = candidate == helix_encoded_case::rtx8 ? 8 :
					                            candidate == helix_encoded_case::gap9 ? 9 : 0;
					std::fprintf(stderr,
					             "HELIX_ENCODED_INJECT scenario=%s stream=0 frame=%llu encoded_bytes=%zu drop_first=%u drop_count=%u\n",
					             helix_encoded_case_name(candidate),
					             static_cast<unsigned long long>(shard.frame_idx),
					             data.size(),
					             candidate == helix_encoded_case::full_reference ? 0u : 2u,
					             drop_count);
					std::fflush(stderr);
				}
			}
		}
	}
'''
text = text.replace(send_start, send_insert, 1)

old_send = '''\t\ttry\n\t\t{\n\t\t\tif (control)\n\t\t\t\tcnx->send_control(to_headset::video_stream_data_shard{shard});\n\t\t\telse\n\t\t\t\tcnx->send_stream(to_headset::video_stream_data_shard{shard});\n\t\t}\n\t\tcatch (...)\n\t\t{\n\t\t\t++helix_initial_send_errors;\n\t\t\t// Ignore network errors\n\t\t}\n'''
new_send = r'''		bool helix_drop = false;
		if (encoded_case == helix_encoded_case::full_reference)
			helix_drop = !control;
		else if (encoded_case == helix_encoded_case::rtx8)
			helix_drop = !control && shard.shard_idx >= 2 && shard.shard_idx < 10;
		else if (encoded_case == helix_encoded_case::gap9)
			helix_drop = !control && shard.shard_idx >= 2 && shard.shard_idx < 11;

		if (helix_drop)
		{
			std::scoped_lock torture_lock(helix_encoded_torture.mutex);
			if (auto record = helix_encoded_torture.records.find(shard.frame_idx); record != helix_encoded_torture.records.end())
				++record->second.dropped;
		}
		else
		{
			try
			{
				if (control)
					cnx->send_control(to_headset::video_stream_data_shard{shard});
				else
					cnx->send_stream(to_headset::video_stream_data_shard{shard});
			}
			catch (...)
			{
				++helix_initial_send_errors;
				// Ignore network errors
			}
		}
'''
if text.count(old_send) != 1:
    raise SystemExit('error: UDP send block anchor not unique')
text = text.replace(old_send, new_send, 1)

old_eof = '''\tif (end_of_frame)\n\t{\n\t\tauto send_span_us = helix_duration_us(helix_pacing_clock::now(), helix_frame_send_started_at);\n'''
new_eof = '''\tif (end_of_frame)\n\t{\n\t\tif (encoded_case != helix_encoded_case::none)\n\t\t{\n\t\t\tstd::scoped_lock torture_lock(helix_encoded_torture.mutex);\n\t\t\tif (auto record = helix_encoded_torture.records.find(shard.frame_idx); record != helix_encoded_torture.records.end())\n\t\t\t{\n\t\t\t\trecord->second.total_shards = helix_current_frame_shards;\n\t\t\t\tstd::fprintf(stderr,\n\t\t\t\t             "HELIX_ENCODED_INJECT_DONE scenario=%s stream=0 frame=%llu dropped=%llu total_shards=%llu\\n",\n\t\t\t\t             helix_encoded_case_name(record->second.scenario),\n\t\t\t\t             static_cast<unsigned long long>(record->second.frame),\n\t\t\t\t             static_cast<unsigned long long>(record->second.dropped),\n\t\t\t\t             static_cast<unsigned long long>(record->second.total_shards));\n\t\t\t\tstd::fflush(stderr);\n\t\t\t}\n\t\t}\n\t\tauto send_span_us = helix_duration_us(helix_pacing_clock::now(), helix_frame_send_started_at);\n'''
if text.count(old_eof) != 1:
    raise SystemExit('error: end-of-frame anchor not unique')
text = text.replace(old_eof, new_eof, 1)
ve.write_text(text)

nv = Path("server/encoder/video_encoder_nvenc.cpp")
text = nv.read_text()
if '#include <cstdio>\n' not in text:
    anchor = '#include <algorithm>\n'
    if text.count(anchor) != 1:
        raise SystemExit('error: nvenc algorithm include anchor not unique')
    text = text.replace(anchor, anchor + '#include <cstdio>\n', 1)

cap = '''\tU_LOG_I("Helix NVENC reference invalidation stream=%u supported=%d",\n\t        stream_idx,\n\t        helix_ref_invalidation_supported);\n'''
cap_new = cap + '''\tstd::fprintf(stderr, "HELIX_ENCODED_NVENC_CAP stream=%u supported=%d\\n", stream_idx, helix_ref_invalidation_supported);\n\tstd::fflush(stderr);\n'''
if text.count(cap) != 1:
    raise SystemExit('error: nvenc cap anchor not unique')
text = text.replace(cap, cap_new, 1)

ok = '''\t\t\tU_LOG_I("Helix NVENC invalidated reference stream=%u frame=%llu",\n\t\t\t        stream_idx,\n\t\t\t        static_cast<unsigned long long>(frame_index));\n'''
ok_new = ok + '''\t\t\tstd::fprintf(stderr,\n\t\t\t             "HELIX_ENCODED_INVALIDATION stream=%u frame=%llu action=applied\\n",\n\t\t\t             stream_idx,\n\t\t\t             static_cast<unsigned long long>(frame_index));\n\t\t\tstd::fflush(stderr);\n'''
if text.count(ok) != 1:
    raise SystemExit('error: nvenc invalidation success anchor not unique')
text = text.replace(ok, ok_new, 1)

fail = '''\t\t\tU_LOG_W("Helix NVENC reference invalidation failed stream=%u frame=%llu status=%d; falling back to IDR",\n\t\t\t        stream_idx,\n\t\t\t        static_cast<unsigned long long>(frame_index),\n\t\t\t        static_cast<int>(status));\n'''
fail_new = fail + '''\t\t\tstd::fprintf(stderr,\n\t\t\t             "HELIX_ENCODED_INVALIDATION stream=%u frame=%llu action=fallback_idr status=%d\\n",\n\t\t\t             stream_idx,\n\t\t\t             static_cast<unsigned long long>(frame_index),\n\t\t\t             static_cast<int>(status));\n\t\t\tstd::fflush(stderr);\n'''
if text.count(fail) != 1:
    raise SystemExit('error: nvenc invalidation failure anchor not unique')
text = text.replace(fail, fail_new, 1)
nv.write_text(text)
PY

echo "[1/9] Applying encoded NVENC torture instrumentation"
python3 "${out}/apply_encoded_torture.py"

echo "[2/9] Formatting and source-scope audit"
clang-format -i -style=file server/encoder/video_encoder.cpp server/encoder/video_encoder_nvenc.cpp
clang-format --dry-run --Werror server/encoder/video_encoder.cpp server/encoder/video_encoder_nvenc.cpp
git diff --check
mapfile -t changed < <(git diff --name-only)
[[ ${#changed[@]} -eq 2 ]] || { echo "error: expected two changed source files" >&2; printf '%s\n' "${changed[@]}" >&2; exit 2; }
[[ " ${changed[*]} " == *" server/encoder/video_encoder.cpp "* ]] || { echo "error: video_encoder.cpp not changed" >&2; exit 2; }
[[ " ${changed[*]} " == *" server/encoder/video_encoder_nvenc.cpp "* ]] || { echo "error: nvenc source not changed" >&2; exit 2; }
for marker in HELIX_ENCODED_INJECT HELIX_ENCODED_FEEDBACK HELIX_ENCODED_RECOVERY HELIX_ENCODED_TORTURE_SUMMARY; do
    grep -Fq "$marker" server/encoder/video_encoder.cpp || { echo "error: missing $marker" >&2; exit 2; }
done
for marker in HELIX_ENCODED_NVENC_CAP HELIX_ENCODED_INVALIDATION 'inputTimeStamp = frame_index' 'helix_drain_reference_invalidations();'; do
    grep -Fq "$marker" server/encoder/video_encoder_nvenc.cpp || { echo "error: missing NVENC marker $marker" >&2; exit 2; }
done
grep -Fq 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old replay not disabled" >&2; exit 2; }
git diff --stat | tee "${out}/source-stat.txt"
git diff >"${out}/source.diff"

echo "[3/9] Committing exact torture source before compilation"
git add server/encoder/video_encoder.cpp server/encoder/video_encoder_nvenc.cpp
git commit -m "Helix: add deterministic encoded NVENC torture injection" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
version_name="${version_prefix}-${source_commit}"
printf 'source_commit=%s\nversion_name=%s\n' "$source_commit" "$version_name" | tee -a "${out}/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree dirty after commit" >&2; exit 2; }

echo "[4/9] Configuring and building runtime-complete desktop artifacts"
cmake --preset everything 2>&1 | tee "${out}/configure.txt"
cmake --build build-everything --target wivrn-server wivrn-dashboard openxr_wivrn monado -j 2 2>&1 | tee "${out}/build.txt"

config_header="$(find build-everything -type f -name wivrn_config.h -print -quit)"
[[ -n "$config_header" ]] || { echo "error: generated wivrn_config.h missing" >&2; exit 2; }
grep -Eq '#define[[:space:]]+WIVRN_USE_NVENC[[:space:]]+1' "$config_header" || { echo "error: exact build does not enable NVENC" >&2; exit 2; }

echo "[5/9] Verifying desktop build provenance"
grep -Fq "const char git_commit[] = \"${source_commit}\";" build-everything/version.cpp || { echo "error: generated version.cpp lacks exact source commit" >&2; exit 2; }
common_archive="$(find build-everything -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "$common_archive" && -s "$common_archive" ]] || { echo "error: common archive missing" >&2; exit 2; }
ar t "$common_archive" | grep -Fq version.cpp.o || { echo "error: version object absent from common archive" >&2; exit 2; }
nm -C "$common_archive" | grep -Fq 'wivrn::display_version()' || { echo "error: display_version symbol absent" >&2; exit 2; }
ninja -C build-everything -t query server/wivrn-server >"${out}/ninja-server.txt"
grep -Fq 'video_encoder.cpp.o' "${out}/ninja-server.txt" || { echo "error: final server graph lacks base encoder object" >&2; exit 2; }
grep -Fq 'video_encoder_nvenc.cpp.o' "${out}/ninja-server.txt" || { echo "error: final server graph lacks NVENC object" >&2; exit 2; }
server="$(realpath build-everything/server/wivrn-server)"
mapfile -t dashboards < <(find build-everything -type f -name wivrn-dashboard -perm -111 | sort)
[[ ${#dashboards[@]} -eq 1 ]] || { echo "error: expected one dashboard, found ${#dashboards[@]}" >&2; exit 2; }
dashboard="$(realpath "${dashboards[0]}")"
manifest="$(realpath build-everything/openxr_wivrn-dev.json)"
[[ -s "$server" && -s "$dashboard" && -s "$manifest" ]] || { echo "error: runtime desktop artifact missing" >&2; exit 2; }
printf 'server=%s\ndashboard=%s\nopenxr_manifest=%s\nserver_provenance=PASS generated-version-build-graph\n' "$server" "$dashboard" "$manifest" | tee -a "${out}/metadata.txt"

echo "[6/9] Building matching Quest APK"
./gradlew --no-daemon assembleDebug -Pwivrn_version="$version_name" -Pwivrn_app_name="Helix Encoded NVENC Torture" 2>&1 | tee "${out}/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ ${#apks[@]} -eq 1 ]] || { echo "error: expected one debug APK, found ${#apks[@]}" >&2; exit 2; }
apk="${out}/helix-encoded-nvenc-${source_commit:0:12}.apk"
cp "$(realpath "${apks[0]}")" "$apk"
sha256sum "$apk" | tee "${out}/apk.sha256"
printf 'apk=%s\n' "$apk" | tee -a "${out}/metadata.txt"

echo "[7/9] Building tiny headless OpenXR frame driver"
cat >"${out}/helix_headless_driver.cpp" <<'CPP'
#include <openxr/openxr.h>
#include <dlfcn.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

[[noreturn]] static void die(const char * msg, XrResult r = XR_SUCCESS)
{
    std::fprintf(stderr, "HELIX_HEADLESS_FAIL message=%s xr=%d\n", msg, int(r));
    std::fflush(stderr);
    std::exit(2);
}

int main(int argc, char ** argv)
{
    uint32_t target_frames = 220;
    if (argc > 1) target_frames = uint32_t(std::stoul(argv[1]));
    void * lib = dlopen("libopenxr_loader.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) lib = dlopen("libopenxr_loader.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) die("openxr_loader_dlopen");
    auto get_proc = reinterpret_cast<PFN_xrGetInstanceProcAddr>(dlsym(lib, "xrGetInstanceProcAddr"));
    if (!get_proc) die("xrGetInstanceProcAddr_dlsym");

    auto load_global = [&](const char * name, auto & fn) {
        PFN_xrVoidFunction raw = nullptr;
        XrResult r = get_proc(XR_NULL_HANDLE, name, &raw);
        if (XR_FAILED(r) || !raw) die(name, r);
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(raw);
    };

    PFN_xrEnumerateInstanceExtensionProperties enumerate_ext = nullptr;
    PFN_xrCreateInstance create_instance = nullptr;
    load_global("xrEnumerateInstanceExtensionProperties", enumerate_ext);
    load_global("xrCreateInstance", create_instance);

    uint32_t ext_count = 0;
    if (XR_FAILED(enumerate_ext(nullptr, 0, &ext_count, nullptr))) die("enumerate_ext_count");
    std::vector<XrExtensionProperties> exts(ext_count, {XR_TYPE_EXTENSION_PROPERTIES});
    if (XR_FAILED(enumerate_ext(nullptr, ext_count, &ext_count, exts.data()))) die("enumerate_ext_values");
    const char * headless = "XR_MND_headless";
    bool has_headless = false;
    for (const auto & ext : exts) if (std::strcmp(ext.extensionName, headless) == 0) has_headless = true;
    std::fprintf(stderr, "HELIX_HEADLESS_EXT name=%s supported=%d\n", headless, has_headless);
    std::fflush(stderr);
    if (!has_headless) die("XR_MND_headless_unavailable");

    XrInstanceCreateInfo ici{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strncpy(ici.applicationInfo.applicationName, "Helix Headless Driver", XR_MAX_APPLICATION_NAME_SIZE - 1);
    ici.applicationInfo.applicationVersion = 1;
    std::strncpy(ici.applicationInfo.engineName, "Helix", XR_MAX_ENGINE_NAME_SIZE - 1);
    ici.applicationInfo.engineVersion = 1;
    ici.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;
    ici.enabledExtensionCount = 1;
    ici.enabledExtensionNames = &headless;
    XrInstance instance = XR_NULL_HANDLE;
    XrResult r = create_instance(&ici, &instance);
    if (XR_FAILED(r)) die("xrCreateInstance", r);

    auto load = [&](const char * name, auto & fn) {
        PFN_xrVoidFunction raw = nullptr;
        XrResult x = get_proc(instance, name, &raw);
        if (XR_FAILED(x) || !raw) die(name, x);
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(raw);
    };

    PFN_xrGetSystem get_system = nullptr;
    PFN_xrCreateSession create_session = nullptr;
    PFN_xrPollEvent poll_event = nullptr;
    PFN_xrBeginSession begin_session = nullptr;
    PFN_xrEndSession end_session = nullptr;
    PFN_xrRequestExitSession request_exit = nullptr;
    PFN_xrWaitFrame wait_frame = nullptr;
    PFN_xrBeginFrame begin_frame = nullptr;
    PFN_xrEndFrame end_frame = nullptr;
    PFN_xrDestroySession destroy_session = nullptr;
    PFN_xrDestroyInstance destroy_instance = nullptr;
    load("xrGetSystem", get_system);
    load("xrCreateSession", create_session);
    load("xrPollEvent", poll_event);
    load("xrBeginSession", begin_session);
    load("xrEndSession", end_session);
    load("xrRequestExitSession", request_exit);
    load("xrWaitFrame", wait_frame);
    load("xrBeginFrame", begin_frame);
    load("xrEndFrame", end_frame);
    load("xrDestroySession", destroy_session);
    load("xrDestroyInstance", destroy_instance);

    XrSystemGetInfo sgi{XR_TYPE_SYSTEM_GET_INFO};
    sgi.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system = XR_NULL_SYSTEM_ID;
    r = get_system(instance, &sgi, &system);
    if (XR_FAILED(r)) die("xrGetSystem", r);

    XrSessionCreateInfo sci{XR_TYPE_SESSION_CREATE_INFO};
    sci.systemId = system;
    XrSession session = XR_NULL_HANDLE;
    r = create_session(instance, &sci, &session);
    if (XR_FAILED(r)) die("xrCreateSession_headless", r);

    bool running = false;
    bool stopping = false;
    auto startup_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (!running && std::chrono::steady_clock::now() < startup_deadline)
    {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        while (poll_event(instance, &event) == XR_SUCCESS)
        {
            if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
            {
                auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&event);
                std::fprintf(stderr, "HELIX_HEADLESS_STATE state=%d\n", int(changed->state));
                std::fflush(stderr);
                if (changed->state == XR_SESSION_STATE_READY)
                {
                    XrSessionBeginInfo bi{XR_TYPE_SESSION_BEGIN_INFO};
                    bi.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                    r = begin_session(session, &bi);
                    if (XR_FAILED(r)) die("xrBeginSession", r);
                    running = true;
                }
            }
            event = {XR_TYPE_EVENT_DATA_BUFFER};
        }
        if (!running) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (!running) die("session_never_ready");

    uint32_t produced = 0;
    for (; produced < target_frames; ++produced)
    {
        XrFrameWaitInfo wi{XR_TYPE_FRAME_WAIT_INFO};
        XrFrameState fs{XR_TYPE_FRAME_STATE};
        r = wait_frame(session, &wi, &fs);
        if (XR_FAILED(r)) die("xrWaitFrame", r);
        XrFrameBeginInfo bi{XR_TYPE_FRAME_BEGIN_INFO};
        r = begin_frame(session, &bi);
        if (XR_FAILED(r)) die("xrBeginFrame", r);
        XrFrameEndInfo ei{XR_TYPE_FRAME_END_INFO};
        ei.displayTime = fs.predictedDisplayTime;
        ei.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
        ei.layerCount = 0;
        ei.layers = nullptr;
        r = end_frame(session, &ei);
        if (XR_FAILED(r)) die("xrEndFrame", r);
        if ((produced + 1) % 30 == 0)
        {
            std::fprintf(stderr, "HELIX_HEADLESS_PROGRESS frames=%u\n", produced + 1);
            std::fflush(stderr);
        }
    }

    std::fprintf(stderr, "HELIX_HEADLESS_DONE frames=%u\n", produced);
    std::fflush(stderr);
    request_exit(session);
    auto stop_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < stop_deadline && !stopping)
    {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        while (poll_event(instance, &event) == XR_SUCCESS)
        {
            if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
            {
                auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&event);
                if (changed->state == XR_SESSION_STATE_STOPPING) stopping = true;
            }
            event = {XR_TYPE_EVENT_DATA_BUFFER};
        }
        if (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (stopping) end_session(session);
    destroy_session(session);
    destroy_instance(instance);
    dlclose(lib);
    return 0;
}
CPP
openxr_header="$(find build-everything/_deps -type f -path '*/openxr/openxr.h' -print -quit)"
[[ -n "$openxr_header" ]] || { echo "error: OpenXR headers not found in configured dependency tree" >&2; exit 2; }
openxr_include="$(dirname "$(dirname "$openxr_header")")"
c++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$openxr_include" "${out}/helix_headless_driver.cpp" -ldl -o "${out}/helix-headless-driver"
[[ -x "${out}/helix-headless-driver" ]] || { echo "error: headless driver build failed" >&2; exit 2; }
printf 'headless_driver=%s\nheadless_driver_source=%s\n' "${out}/helix-headless-driver" "${out}/helix_headless_driver.cpp" | tee -a "${out}/metadata.txt"

echo "[8/9] Publishing only exact fully-built source checkpoint"
git push origin "HEAD:refs/heads/${source_branch}" 2>&1 | tee "${out}/push.txt"
remote_head="$(git ls-remote origin "refs/heads/${source_branch}" | awk '{print $1}')"
[[ "$remote_head" == "$source_commit" ]] || { echo "error: remote branch does not point to built commit" >&2; exit 2; }
printf 'remote_head=%s\n' "$remote_head" | tee -a "${out}/metadata.txt"

echo "[9/9] Final artifact gate"
printf 'artifact_gate=PASS exact-commit-runtime-dashboard-apk-headless-driver\n' | tee -a "${out}/metadata.txt"
printf '\nPASS: encoded NVENC torture source committed, runtime-complete desktop artifacts + matching APK + headless driver built, exact commit published.\n'
printf 'commit=%s\nbranch=%s\nserver=%s\ndashboard=%s\napk=%s\nheadless_driver=%s\nevidence=%s\n' \
    "$source_commit" "$source_branch" "$server" "$dashboard" "$apk" "${out}/helix-headless-driver" "$out"
printf 'STATUS: built only; not installed and encoded runtime not executed.\n'
