#!/usr/bin/env bash
set -euo pipefail

source_commit="6fb60e5fb4f82fc7306ba4db85ba190797393946"
package="org.meumeu.wivrn.local"
activity="org.meumeu.wivrn.MainActivity"
version_name="helix-boundary-${source_commit}"

for cmd in adb grep sed awk sha256sum sort tail head ip timeout pgrep kill python3; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

out="${HOME}/helix-quest-transport-boundary-coarse-${source_commit:0:12}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"

mapfile -t meta_candidates < <(grep -l "^source_commit=${source_commit}$" "${HOME}"/helix-quest-boundary-recovery-build-*/metadata.txt 2>/dev/null || true)
[[ "${#meta_candidates[@]}" -gt 0 ]] || { echo "error: no preserved boundary build for ${source_commit}" >&2; exit 2; }
artifact_meta="$(printf '%s\n' "${meta_candidates[@]}" | sort | tail -1)"
server="$(sed -n 's/^server=//p' "${artifact_meta}" | tail -1)"
apk="$(sed -n 's/^apk=//p' "${artifact_meta}" | tail -1)"
[[ -x "${server}" ]] || { echo "error: preserved boundary server missing: ${server}" >&2; exit 2; }
[[ -s "${apk}" ]] || { echo "error: preserved boundary APK missing: ${apk}" >&2; exit 2; }
grep -Fqx 'server_provenance=PASS generated-version-build-graph' "${artifact_meta}" || { echo "error: server provenance marker missing" >&2; exit 2; }
grep -Fqx 'artifact_gate=PASS exact-commit-server-and-apk' "${artifact_meta}" || { echo "error: exact artifact gate marker missing" >&2; exit 2; }
grep -Fqx 'compile_recovery=PASS unused-helper-class-closed' "${artifact_meta}" || { echo "error: compile recovery marker missing" >&2; exit 2; }
apk_sha_file="$(dirname "${artifact_meta}")/apk.sha256"
[[ -s "${apk_sha_file}" ]] || { echo "error: APK sha256 evidence missing" >&2; exit 2; }
expected_sha="$(awk '{print $1}' "${apk_sha_file}" | head -1)"
actual_sha="$(sha256sum "${apk}" | awk '{print $1}')"
[[ "${actual_sha}" == "${expected_sha}" ]] || { echo "error: APK sha256 mismatch" >&2; exit 2; }

mapfile -t all_devices < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t usb_devices < <(printf '%s\n' "${all_devices[@]}" | grep -v ':' || true)
if [[ "${#usb_devices[@]}" -eq 1 ]]; then
    serial="${usb_devices[0]}"
elif [[ "${#all_devices[@]}" -eq 1 ]]; then
    serial="${all_devices[0]}"
else
    echo "error: expected one usable ADB device; found ${#all_devices[@]}" >&2
    printf '%s\n' "${all_devices[@]}" >&2
    exit 2
fi
adbq=(adb -s "${serial}")

printf 'source_commit=%s\nartifact_metadata=%s\nserver=%s\napk=%s\napk_sha256=%s\nadb_serial=%s\nphase=coarse-boundary-map\n' \
    "${source_commit}" "${artifact_meta}" "${server}" "${apk}" "${actual_sha}" "${serial}" >"${out}/metadata.txt"

logcat_pid=""
server_pid=""
active_units=()
cleanup() {
    set +e
    [[ -z "${server_pid}" ]] || kill "${server_pid}" >/dev/null 2>&1 || true
    [[ -z "${logcat_pid}" ]] || kill "${logcat_pid}" >/dev/null 2>&1 || true
    "${adbq[@]}" shell am force-stop "${package}" >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null 2>&1; then
        for unit in "${active_units[@]}"; do systemctl --user start "${unit}" >/dev/null 2>&1 || true; done
    fi
}
trap cleanup EXIT INT TERM

echo "[1/8] Verifying Quest is awake"
"${adbq[@]}" shell dumpsys power >"${out}/power-before.txt"
grep -Eq 'mWakefulness=Awake|Wakefulness: Awake' "${out}/power-before.txt" || { echo "error: Quest is not awake" >&2; exit 2; }

echo "[2/8] Installing exact matching boundary APK"
set +e
"${adbq[@]}" install -r -d "${apk}" 2>&1 | tee "${out}/adb-install.txt"
install_status=${PIPESTATUS[0]}
set -e
(( install_status == 0 )) || { echo "error: adb install failed; app data preserved" >&2; exit "${install_status}"; }
"${adbq[@]}" shell dumpsys package "${package}" >"${out}/package.txt"
grep -Fq "versionName=${version_name}" "${out}/package.txt" || { echo "error: installed package version does not match ${version_name}" >&2; exit 2; }

echo "[3/8] Deriving transport addresses and isolating existing server"
quest_ip="$("${adbq[@]}" shell ip -4 addr show wlan0 | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1 | tr -d '\r')"
[[ -n "${quest_ip}" ]] || { echo "error: could not determine Quest wlan0 IPv4 address" >&2; exit 2; }
host_ip="$(ip -4 route get "${quest_ip}" | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[[ -n "${host_ip}" ]] || { echo "error: could not determine host route address" >&2; exit 2; }
printf 'quest_ip=%s\nhost_ip=%s\n' "$quest_ip" "$host_ip" | tee "${out}/route.txt" >>"${out}/metadata.txt"
if command -v systemctl >/dev/null 2>&1; then
    mapfile -t active_units < <(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk 'tolower($1) ~ /wivrn/ {print $1}')
    for unit in "${active_units[@]}"; do systemctl --user stop "${unit}" || true; done
fi
mapfile -t old_pids < <(pgrep -u "${UID}" -x wivrn-server 2>/dev/null || true)
if [[ "${#old_pids[@]}" -gt 0 ]]; then
    kill -TERM "${old_pids[@]}" 2>/dev/null || true
    for _ in {1..20}; do sleep 0.1; pgrep -u "${UID}" -x wivrn-server >/dev/null 2>&1 || break; done
fi
pgrep -u "${UID}" -x wivrn-server >/dev/null 2>&1 && { echo "error: existing wivrn-server still running" >&2; exit 2; }

echo "[4/8] Starting Quest log capture"
"${adbq[@]}" logcat -c
"${adbq[@]}" logcat -v threadtime >"${out}/quest-logcat.txt" 2>&1 &
logcat_pid=$!

echo "[5/8] Starting exact coarse boundary server"
set +e
timeout --signal=TERM --kill-after=5s 180s "${server}" --helix-synthetic-transport >"${out}/server.log" 2>&1 &
server_pid=$!
set -e
sleep 2
kill -0 "${server_pid}" 2>/dev/null || { echo "error: boundary server exited before Quest launch" >&2; tail -80 "${out}/server.log" >&2; exit 2; }

echo "[6/8] Launching Quest directly at boundary server"
"${adbq[@]}" shell am force-stop "${package}"
"${adbq[@]}" shell am start -W -a android.intent.action.VIEW -d "wivrn+tcp://${host_ip}" -n "${package}/${activity}" | tee "${out}/launch.txt"
set +e
wait "${server_pid}"
server_status=$?
set -e
server_pid=""
sleep 2
kill "${logcat_pid}" >/dev/null 2>&1 || true
wait "${logcat_pid}" >/dev/null 2>&1 || true
logcat_pid=""

echo "[7/8] Reducing coarse cliff map"
set +e
python3 - "$server_status" "${out}/server.log" "${out}/quest-logcat.txt" "${out}/boundary-summary.txt" <<'PY'
import re, sys
from collections import defaultdict
from pathlib import Path
server_status=int(sys.argv[1])
server=Path(sys.argv[2]).read_text(errors='replace')
quest=Path(sys.argv[3]).read_text(errors='replace')
out=Path(sys.argv[4])

case_re=re.compile(r'^HELIX_BOUNDARY axis=(\S+) level=(\d+) stream=(\d+) class=(\S+) mode=(\S+) primary_ok=(\d+) recovery_ok=(\d+) gap_ok=(\d+) feedback=(\d+) gaps=(\d+) rtx=(\d+)$', re.M)
rows=[]
for m in case_re.finditer(server):
    axis,level,stream,cls,mode,primary,recovery,gap,feedback,gaps,rtx=m.groups()
    rows.append(dict(axis=axis, level=int(level), stream=int(stream), cls=cls, mode=mode,
                     primary=int(primary), recovery=int(recovery), gap=int(gap), feedback=int(feedback), gaps=int(gaps), rtx=int(rtx)))
result_lines=re.findall(r'^HELIX_BOUNDARY_RESULT.*$',server,re.M)
exit_lines=re.findall(r'^.*HELIX_SYNTHETIC_TRANSPORT_EXIT result=(\d+).*$' ,server,re.M)
quest_crash=bool(re.search(r'Fatal signal\s+\d+.*(?:meu\.wivrn\.local|pid\s+\d+)|Abort message:.*(?:org\.meumeu\.wivrn\.local|client/scenes/stream\.cpp|assertion)',quest,re.I))

report=[]
report.append('phase=coarse-boundary-map')
report.append(f'cases_observed={len(rows)}')
report.append(f'quest_crash={int(quest_crash)}')
report.append(f'server_status={server_status}')
if result_lines: report.append(result_lines[-1])
if exit_lines: report.append(f'HELIX_SYNTHETIC_TRANSPORT_EXIT result={exit_lines[-1]}')

by=defaultdict(lambda: defaultdict(list))
for r in rows:
    by[r['axis']][r['level']].append(r)

for axis in ['baseline','loss_depth','full_frame_run','reorder_distance','lateness_ms','frame_jump','rtx_pressure','duplicate_density']:
    levels=by.get(axis,{})
    if not levels:
        report.append(f'AXIS {axis} observed=0')
        continue
    level_summaries=[]
    for level in sorted(levels):
        rr=levels[level]
        classes=[r['cls'] for r in rr]
        clean=sum(c in ('clean_success','clean_recovery') for c in classes)
        degraded=sum(c=='degraded' for c in classes)
        hard=sum(c=='hard_failure' for c in classes)
        modes=','.join(sorted(set(r['mode'] for r in rr)))
        level_summaries.append((level,len(rr),clean,degraded,hard,modes,classes))
        report.append(f'LEVEL axis={axis} level={level} samples={len(rr)} clean={clean} degraded={degraded} hard={hard} modes={modes} classes={",".join(classes)}')
    all_clean=[x[0] for x in level_summaries if x[2]==x[1]]
    any_recovery=[x[0] for x in level_summaries if any(c=='clean_recovery' for c in x[6])]
    any_degraded=[x[0] for x in level_summaries if x[3]>0]
    any_hard=[x[0] for x in level_summaries if x[4]>0]
    last_clean=max(all_clean) if all_clean else 'none'
    first_recovery=min(any_recovery) if any_recovery else 'none'
    first_degraded=min(any_degraded) if any_degraded else 'none'
    first_hard=min(any_hard) if any_hard else 'none'
    report.append(f'AXIS {axis} last_all_clean={last_clean} first_clean_recovery={first_recovery} first_degraded={first_degraded} first_hard={first_hard}')

valid = bool(rows) and bool(result_lines) and bool(exit_lines) and not quest_crash
# A terminal boundary (run result 3 / process nonzero) is diagnostic success if
# the authoritative boundary result is present; this phase is intentionally
# allowed to discover hard failure. Missing evidence or client crash is not.
if valid:
    verdict='BOUNDARY_MAP_COMPLETE' if 'completed=1' in result_lines[-1] else 'BOUNDARY_TERMINAL_FOUND'
else:
    verdict='BOUNDARY_MAP_INVALID'
report.insert(0,f'verdict={verdict}')
out.write_text('\n'.join(report)+'\n')
print(out.read_text(),end='')
raise SystemExit(0 if valid else 1)
PY
reduce_status=$?
set -e

echo "[8/8] Boundary evidence verdict"
if (( reduce_status == 0 )); then
    grep '^verdict=' "${out}/boundary-summary.txt"
    echo "PASS: coarse boundary evidence is diagnostic. This is not a promotion percentage gate."
else
    echo "FAIL: boundary evidence is nondiagnostic; preserve evidence and classify before rerun."
fi
printf 'evidence=%s\n' "${out}"
exit "${reduce_status}"
