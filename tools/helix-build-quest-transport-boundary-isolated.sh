#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

base_commit="a97cf8add2c0e90954b45523dca3346fbb40e93d"
source_branch="helix-quest-transport-boundary-map"
source_path="server/helix_synthetic_transport.cpp"
version_prefix="helix-boundary"

for cmd in git python3 clang-format cmake ninja ar nm realpath grep find java sha256sum rsvg-convert; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

git cat-file -e "${base_commit}^{commit}" 2>/dev/null || git fetch origin "${base_commit}"
git cat-file -e "${base_commit}^{commit}" 2>/dev/null || { echo "error: base commit ${base_commit} unavailable" >&2; exit 2; }

if git ls-remote --exit-code --heads origin "${source_branch}" >/dev/null 2>&1; then
    echo "error: origin/${source_branch} already exists; classify existing state before rebuilding" >&2
    exit 2
fi

out="${HOME}/helix-quest-boundary-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'base_commit=%s\nsource_branch=%s\ncaller_head=%s\n' \
    "${base_commit}" "${source_branch}" "$(git rev-parse HEAD)" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${base_commit}" >/dev/null
cd "${worktree}"
[[ "$(git rev-parse HEAD)" == "${base_commit}" ]] || { echo "error: wrong isolated base commit" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated worktree dirty at creation" >&2; exit 2; }

cat >"${out}/apply_boundary.py" <<'PY'
from pathlib import Path

path = Path("server/helix_synthetic_transport.cpp")
text = path.read_text()

anonymous_close = "} // namespace\n\nint run(wivrn_connection & connection, std::stop_token stop_token)\n"
if text.count(anonymous_close) != 1:
    raise SystemExit(f"error: anonymous namespace/run anchor count={text.count(anonymous_close)}")

helpers = r'''
enum class boundary_class
{
	clean_success,
	clean_recovery,
	degraded,
	hard_failure,
};

const char * boundary_name(boundary_class c)
{
	switch (c)
	{
		case boundary_class::clean_success: return "clean_success";
		case boundary_class::clean_recovery: return "clean_recovery";
		case boundary_class::degraded: return "degraded";
		case boundary_class::hard_failure: return "hard_failure";
	}
	return "unknown";
}

struct boundary_score
{
	uint64_t cases = 0;
	uint64_t clean_success = 0;
	uint64_t clean_recovery = 0;
	uint64_t degraded = 0;
	uint64_t hard = 0;
	bool terminal = false;
};

void note_boundary(boundary_score & score,
                   const char * axis,
                   uint64_t level,
                   uint8_t stream,
                   boundary_class classification,
                   bool primary_ok,
                   bool recovery_ok,
                   bool gap_ok,
                   size_t feedback,
                   size_t gaps,
                   size_t rtx,
                   const char * mode)
{
	++score.cases;
	switch (classification)
	{
		case boundary_class::clean_success: ++score.clean_success; break;
		case boundary_class::clean_recovery: ++score.clean_recovery; break;
		case boundary_class::degraded: ++score.degraded; break;
		case boundary_class::hard_failure: ++score.hard; break;
	}
	std::fprintf(stderr,
	             "HELIX_BOUNDARY axis=%s level=%llu stream=%u class=%s mode=%s primary_ok=%d recovery_ok=%d gap_ok=%d feedback=%zu gaps=%zu rtx=%zu\n",
	             axis,
	             static_cast<unsigned long long>(level),
	             stream,
	             boundary_name(classification),
	             mode,
	             primary_ok,
	             recovery_ok,
	             gap_ok,
	             feedback,
	             gaps,
	             rtx);
	std::fflush(stderr);
}

bool resync(sender & tx, wivrn_connection & connection, uint8_t stream, uint64_t & frame, const char * axis)
{
	observation obs;
	frame += 4;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = frame});
	collect(connection, obs, per_scenario_timeout);
	const bool ok = feedback_success(obs, stream, frame);
	std::fprintf(stderr,
	             "HELIX_BOUNDARY_RESYNC axis=%s stream=%u frame=%llu pass=%d feedback=%zu gaps=%zu rtx=%zu\n",
	             axis,
	             stream,
	             static_cast<unsigned long long>(frame),
	             ok,
	             obs.feedback.size(),
	             obs.gaps.size(),
	             obs.rtx.size());
	std::fflush(stderr);
	++frame;
	return ok;
}

boundary_class boundary_loss_depth(sender & tx,
                                   wivrn_connection & connection,
                                   uint8_t stream,
                                   uint64_t & frame,
                                   uint16_t missing,
                                   boundary_score & score)
{
	observation obs;
	const uint16_t start = missing == shards_per_frame ? 0 : (missing ? 1 : 0);
	const uint64_t first_missing = tx.next_sequence(stream) + start;
	const uint64_t base = frame;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base, .omitted = contiguous_omission(missing, start)});
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + 1});
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = missing ? feedback_incomplete(obs, stream, base) : feedback_success(obs, stream, base);
	const bool recovery_ok = feedback_success(obs, stream, base + 1);
	const bool gap_ok = missing == 0 || gap_covers(obs, stream, first_missing, missing);
	boundary_class c;
	if (missing == 0 && primary_ok && recovery_ok)
		c = boundary_class::clean_success;
	else if (missing > 0 && primary_ok && recovery_ok && gap_ok)
		c = boundary_class::clean_recovery;
	else if (recovery_ok)
		c = boundary_class::degraded;
	else
		c = boundary_class::hard_failure;
	frame = base + 2;
	note_boundary(score, "loss_depth", missing, stream, c, primary_ok, recovery_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), missing ? "next_frame" : "none");
	return c;
}

boundary_class boundary_full_frame_run(sender & tx,
                                       wivrn_connection & connection,
                                       uint8_t stream,
                                       uint64_t & frame,
                                       uint16_t count,
                                       boundary_score & score)
{
	observation obs;
	const uint64_t first_missing = tx.next_sequence(stream);
	const uint64_t base = frame;
	for (uint16_t i = 0; i < count; ++i)
		tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + i, .omitted = contiguous_omission(shards_per_frame, 0)});
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + count});
	collect(connection, obs, per_scenario_timeout);
	const bool recovery_ok = feedback_success(obs, stream, base + count);
	const bool gap_ok = gap_covers(obs, stream, first_missing, uint64_t(count) * shards_per_frame);
	const bool primary_ok = recovery_ok;
	const boundary_class c = recovery_ok && gap_ok ? boundary_class::clean_recovery :
	                         recovery_ok ? boundary_class::degraded : boundary_class::hard_failure;
	frame = base + count + 1;
	note_boundary(score, "full_frame_run", count, stream, c, primary_ok, recovery_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "frame_jump_recovery");
	return c;
}

boundary_class boundary_reorder_distance(sender & tx,
                                         wivrn_connection & connection,
                                         uint8_t stream,
                                         uint64_t & frame,
                                         uint16_t distance,
                                         boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	tx.send_explicit_shard(stream, base, 0, tx.reserve_sequence(stream));
	const uint64_t held_sequence = tx.reserve_sequence(stream);
	for (uint16_t shard = 2; shard < 2 + distance; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	tx.send_explicit_shard(stream, base, 1, held_sequence);
	for (uint16_t shard = uint16_t(2 + distance); shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = feedback_success(obs, stream, base);
	const bool gap_ok = gap_covers(obs, stream, held_sequence, 1);
	const boundary_class c = primary_ok && gap_ok ? boundary_class::clean_success :
	                         primary_ok ? boundary_class::degraded : boundary_class::hard_failure;
	++frame;
	note_boundary(score, "reorder_distance", distance, stream, c, primary_ok, primary_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "late_same_frame");
	return c;
}

boundary_class boundary_lateness_ms(sender & tx,
                                    wivrn_connection & connection,
                                    uint8_t stream,
                                    uint64_t & frame,
                                    uint16_t delay_ms,
                                    boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	tx.send_explicit_shard(stream, base, 0, tx.reserve_sequence(stream));
	const uint64_t held_sequence = tx.reserve_sequence(stream);
	for (uint16_t shard = 2; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
	tx.send_explicit_shard(stream, base, 1, held_sequence);
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = feedback_success(obs, stream, base);
	const bool gap_ok = gap_covers(obs, stream, held_sequence, 1);
	const boundary_class c = primary_ok && gap_ok ? boundary_class::clean_success :
	                         primary_ok ? boundary_class::degraded : boundary_class::hard_failure;
	++frame;
	note_boundary(score, "lateness_ms", delay_ms, stream, c, primary_ok, primary_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "held_shard");
	return c;
}

boundary_class boundary_frame_jump(sender & tx,
                                   wivrn_connection & connection,
                                   uint8_t stream,
                                   uint64_t & frame,
                                   uint16_t jump,
                                   boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	const uint64_t target = base + jump;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = target});
	collect(connection, obs, per_scenario_timeout);
	const bool recovery_ok = feedback_success(obs, stream, target);
	const bool primary_ok = jump == 0 ? recovery_ok : feedback_incomplete(obs, stream, base);
	const boundary_class c = recovery_ok && (jump == 0 || primary_ok) ? (jump == 0 ? boundary_class::clean_success : boundary_class::clean_recovery) :
	                         recovery_ok ? boundary_class::degraded : boundary_class::hard_failure;
	frame = target + 1;
	note_boundary(score, "frame_jump", jump, stream, c, primary_ok, recovery_ok, true, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), jump ? "jump_recovery" : "none");
	return c;
}

boundary_class boundary_rtx_pressure(sender & tx,
                                     wivrn_connection & connection,
                                     uint8_t stream,
                                     uint64_t & frame,
                                     uint16_t missing,
                                     boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	std::vector<std::pair<uint16_t, uint64_t>> held;
	held.reserve(missing);
	for (uint16_t shard = 0; shard < missing; ++shard)
		held.emplace_back(shard, tx.reserve_sequence(stream));
	for (uint16_t shard = missing; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	collect(connection, obs, 150ms);
	std::set<uint64_t> requested;
	for (const auto & request: obs.rtx)
		if (request.stream_index == stream)
			requested.insert(request.packet_sequence);
	for (const auto & [shard, sequence]: held)
		if (requested.contains(sequence))
			tx.send_explicit_shard(stream, base, shard, sequence, true);
	collect(connection, obs, per_scenario_timeout);
	const bool target_ok = feedback_success(obs, stream, base);
	const bool exact_rtx = requested.size() == missing;
	const bool over_cap = missing > 8;
	if (target_ok && exact_rtx)
	{
		++frame;
		note_boundary(score, "rtx_pressure", missing, stream, boundary_class::clean_recovery, true, true, true, obs.feedback.size(), obs.gaps.size(), requested.size(), "rtx");
		return boundary_class::clean_recovery;
	}

	observation recovery_obs = obs;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + 1});
	collect(connection, recovery_obs, per_scenario_timeout);
	const bool recovery_ok = feedback_success(recovery_obs, stream, base + 1);
	const bool primary_ok = feedback_incomplete(recovery_obs, stream, base);
	boundary_class c;
	const char * mode;
	if (over_cap && requested.empty() && primary_ok && recovery_ok)
	{
		c = boundary_class::clean_recovery;
		mode = "gap_cap_next_frame";
	}
	else if (recovery_ok)
	{
		c = boundary_class::degraded;
		mode = "unexpected_next_frame";
	}
	else
	{
		c = boundary_class::hard_failure;
		mode = "unrecovered";
	}
	frame = base + 2;
	note_boundary(score, "rtx_pressure", missing, stream, c, primary_ok, recovery_ok, true, recovery_obs.feedback.size(), recovery_obs.gaps.size(), requested.size(), mode);
	return c;
}

boundary_class boundary_duplicate_density(sender & tx,
                                          wivrn_connection & connection,
                                          uint8_t stream,
                                          uint64_t & frame,
                                          uint16_t duplicates,
                                          boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	const uint64_t first_sequence = tx.reserve_sequence(stream);
	tx.send_explicit_shard(stream, base, 0, first_sequence);
	for (uint16_t i = 0; i < duplicates; ++i)
		tx.send_explicit_shard(stream, base, 0, first_sequence);
	for (uint16_t shard = 1; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = feedback_success(obs, stream, base);
	const boundary_class c = primary_ok ? boundary_class::clean_success : boundary_class::hard_failure;
	++frame;
	note_boundary(score, "duplicate_density", duplicates, stream, c, primary_ok, primary_ok, true, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "same_sequence");
	return c;
}

'''
text = text.replace(anonymous_close, helpers + anonymous_close, 1)

run_start = text.index("int run(wivrn_connection & connection, std::stop_token stop_token)\n")
run_end_marker = "\n} // namespace wivrn::helix_synthetic_transport\n"
run_end = text.rindex(run_end_marker)

new_run = r'''int run(wivrn_connection & connection, std::stop_token stop_token)
{
	const bool oracle_ok = oracle_self_test();
	std::fprintf(stderr, "HELIX_BOUNDARY_ORACLE pass=%d\n", oracle_ok);
	std::fflush(stderr);
	if (!oracle_ok)
		return 2;

	connection.send_control(to_headset::video_stream_description{
	        .width = width,
	        .height = height,
	        .codec = {video_codec::raw, video_codec::raw, video_codec::raw},
	        .frame_rate = 90.0f,
	        .refresh_rate = 90.0f,
	});
	std::this_thread::sleep_for(setup_delay);

	sender tx{connection, stop_token};
	boundary_score score;
	std::array<uint64_t, 2> frame{};

	// Baseline: both streams must decode cleanly before any boundary work.
	for (uint8_t stream = 0; stream < 2; ++stream)
	{
		observation obs;
		tx.send_frame(packet_plan{.stream = stream, .frame_idx = frame[stream]});
		collect(connection, obs, per_scenario_timeout);
		const bool ok = feedback_success(obs, stream, frame[stream]);
		note_boundary(score, "baseline", 0, stream, ok ? boundary_class::clean_success : boundary_class::hard_failure, ok, ok, true, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "none");
		++frame[stream];
		if (!ok)
		{
			score.terminal = true;
			std::fprintf(stderr, "HELIX_BOUNDARY_RESULT completed=0 cases=%llu clean_success=%llu clean_recovery=%llu degraded=%llu hard=%llu terminal=1\n",
			             static_cast<unsigned long long>(score.cases), static_cast<unsigned long long>(score.clean_success), static_cast<unsigned long long>(score.clean_recovery), static_cast<unsigned long long>(score.degraded), static_cast<unsigned long long>(score.hard));
			std::fflush(stderr);
			return 3;
		}
	}

	const std::array<uint16_t, 10> loss_levels{0, 1, 2, 4, 8, 16, 24, 32, 48, 64};
	const std::array<uint16_t, 7> full_run_levels{1, 2, 4, 8, 16, 32, 64};
	const std::array<uint16_t, 8> reorder_levels{1, 2, 4, 8, 16, 32, 48, 62};
	const std::array<uint16_t, 11> lateness_levels{0, 1, 2, 5, 10, 20, 40, 80, 160, 320, 640};
	const std::array<uint16_t, 10> jump_levels{1, 2, 3, 4, 8, 16, 32, 64, 128, 256};
	const std::array<uint16_t, 8> rtx_levels{1, 2, 4, 8, 9, 12, 16, 24};
	const std::array<uint16_t, 8> duplicate_levels{0, 1, 2, 4, 8, 16, 32, 64};

	auto handle_hard = [&](boundary_class c, uint8_t stream, const char * axis) {
		if (c != boundary_class::hard_failure)
			return true;
		if (resync(tx, connection, stream, frame[stream], axis))
			return true;
		score.terminal = true;
		return false;
	};

	for (auto level: loss_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_loss_depth(tx, connection, stream, frame[stream], level, score), stream, "loss_depth")) goto done;

	for (auto level: full_run_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_full_frame_run(tx, connection, stream, frame[stream], level, score), stream, "full_frame_run")) goto done;

	for (auto level: reorder_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_reorder_distance(tx, connection, stream, frame[stream], level, score), stream, "reorder_distance")) goto done;

	for (auto level: lateness_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_lateness_ms(tx, connection, stream, frame[stream], level, score), stream, "lateness_ms")) goto done;

	for (auto level: jump_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_frame_jump(tx, connection, stream, frame[stream], level, score), stream, "frame_jump")) goto done;

	for (auto level: rtx_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_rtx_pressure(tx, connection, stream, frame[stream], level, score), stream, "rtx_pressure")) goto done;

	for (auto level: duplicate_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_duplicate_density(tx, connection, stream, frame[stream], level, score), stream, "duplicate_density")) goto done;

done:
	std::fprintf(stderr,
	             "HELIX_BOUNDARY_RESULT completed=%d cases=%llu clean_success=%llu clean_recovery=%llu degraded=%llu hard=%llu terminal=%d\n",
	             score.terminal ? 0 : 1,
	             static_cast<unsigned long long>(score.cases),
	             static_cast<unsigned long long>(score.clean_success),
	             static_cast<unsigned long long>(score.clean_recovery),
	             static_cast<unsigned long long>(score.degraded),
	             static_cast<unsigned long long>(score.hard),
	             score.terminal ? 1 : 0);
	std::fflush(stderr);
	return score.terminal ? 3 : 0;
}
'''

text = text[:run_start] + new_run + text[run_end:]
path.write_text(text)
PY

echo "[1/8] Applying Quest transport boundary-map battery"
python3 "${out}/apply_boundary.py"

echo "[2/8] Formatting and exact-scope audit"
clang-format -i -style=file "${source_path}"
clang-format --dry-run --Werror "${source_path}"
git diff --check -- "${source_path}"
mapfile -t changed < <(git diff --name-only)
[[ "${#changed[@]}" -eq 1 && "${changed[0]}" == "${source_path}" ]] || {
    echo "error: unexpected changed paths" >&2
    printf '%s\n' "${changed[@]}" >&2
    exit 2
}
for marker in \
    'HELIX_BOUNDARY axis=' \
    'HELIX_BOUNDARY_RESULT' \
    'axis, "loss_depth"' \
    '"full_frame_run"' \
    '"reorder_distance"' \
    '"lateness_ms"' \
    '"frame_jump"' \
    '"rtx_pressure"' \
    '"duplicate_density"' \
    'foveation.x = {width};' \
    'foveation.y = {height};'; do
    grep -Fq -- "${marker}" "${source_path}" || { echo "error: boundary/source marker missing: ${marker}" >&2; exit 2; }
done
grep -Fq -- 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old full replay is not disabled" >&2; exit 2; }
# The boundary branch deliberately reuses the already-audited synthetic CLI mode;
# runtime artifact identity, not flag spelling, selects the boundary battery.
grep -Fq -- '--helix-synthetic-transport' server/main.cpp || { echo "error: synthetic transport CLI mode missing" >&2; exit 2; }
git diff --stat | tee "${out}/source-stat.txt"
git diff >"${out}/source.diff"

echo "[3/8] Committing exact boundary source before compilation"
git add -- "${source_path}"
git commit -m "Helix: add Quest transport hard-limit boundary map" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
version_name="${version_prefix}-${source_commit}"
printf 'source_commit=%s\nversion_name=%s\n' "${source_commit}" "${version_name}" | tee -a "${out}/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree dirty after commit" >&2; exit 2; }

echo "[4/8] Publishing exact boundary checkpoint"
git push origin "HEAD:refs/heads/${source_branch}" 2>&1 | tee "${out}/push.txt"

echo "[5/8] Building exact committed wivrn-server"
cmake --preset server 2>&1 | tee "${out}/configure-server.txt"
set +e
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "${out}/build-server.txt"
server_build_status=${PIPESTATUS[0]}
set -e
(( server_build_status == 0 )) || exit "${server_build_status}"

echo "[6/8] Verifying server build-graph provenance"
grep -Fq "const char git_commit[] = \"${source_commit}\";" build-server/version.cpp || { echo "error: generated version.cpp lacks exact source commit" >&2; exit 2; }
common_archive="$(find build-server -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "${common_archive}" && -s "${common_archive}" ]] || { echo "error: common-base archive not found" >&2; exit 2; }
ar t "${common_archive}" | grep -Fq 'version.cpp.o' || { echo "error: common-base archive lacks version.cpp.o" >&2; exit 2; }
nm -C "${common_archive}" | grep -Fq 'wivrn::display_version()' || { echo "error: common-base archive lacks display_version symbol" >&2; exit 2; }
ninja -C build-server -t query server/wivrn-server >"${out}/ninja-query.txt"
grep -Fq 'helix_synthetic_transport.cpp.o' "${out}/ninja-query.txt" || { echo "error: final server graph lacks boundary transport object" >&2; exit 2; }
grep -Fq 'Linking CXX executable server/wivrn-server' "${out}/build-server.txt" || { echo "error: build log lacks final server link" >&2; exit 2; }
server="$(realpath build-server/server/wivrn-server)"
[[ -s "${server}" ]] || { echo "error: built server missing or empty" >&2; exit 2; }
printf 'server=%s\nserver_provenance=PASS generated-version-build-graph\n' "${server}" | tee -a "${out}/metadata.txt"

echo "[7/8] Building exact matching Quest APK"
./gradlew --no-daemon assembleDebug \
    -Pwivrn_version="${version_name}" \
    -Pwivrn_app_name="Helix Transport Boundary Map" \
    2>&1 | tee "${out}/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ "${#apks[@]}" -eq 1 ]] || { echo "error: expected exactly one debug APK, found ${#apks[@]}" >&2; exit 2; }
apk_source="$(realpath "${apks[0]}")"
apk="${out}/helix-quest-transport-boundary-${source_commit:0:12}.apk"
cp -- "${apk_source}" "${apk}"
sha256sum "${apk}" | tee "${out}/apk.sha256"
printf 'apk=%s\n' "${apk}" | tee -a "${out}/metadata.txt"
[[ "$(git rev-parse HEAD)" == "${source_commit}" ]] || { echo "error: source HEAD changed during builds" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree changed during builds" >&2; exit 2; }

echo "[8/8] Final boundary artifact gate"
printf 'artifact_gate=PASS exact-commit-server-and-apk\n' | tee -a "${out}/metadata.txt"
printf '\nPASS: Quest transport boundary-map source committed, published, server built, and matching APK built.\n'
printf 'commit=%s\nbranch=%s\nserver=%s\napk=%s\nevidence=%s\n' \
    "${source_commit}" "${source_branch}" "${server}" "${apk}" "${out}"
printf 'STATUS: built only; not installed and boundary runtime not executed.\n'
