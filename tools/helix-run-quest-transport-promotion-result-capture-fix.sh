#!/usr/bin/env bash
set -euo pipefail

source_commit="a97cf8add2c0e90954b45523dca3346fbb40e93d"
package="org.meumeu.wivrn.local"
activity="org.meumeu.wivrn.MainActivity"
version_name="helix-${source_commit}"

for cmd in adb grep sed awk sha256sum sort tail head ip timeout pgrep kill python3; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

out="${HOME}/helix-quest-transport-promotion-${source_commit:0:12}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"

mapfile -t meta_candidates < <(grep -l "^source_commit=${source_commit}$" "${HOME}"/helix-quest-result-capture-fix-build-*/metadata.txt 2>/dev/null || true)
[[ "${#meta_candidates[@]}" -gt 0 ]] || { echo "error: no preserved result-capture-fix build for ${source_commit}" >&2; exit 2; }
artifact_meta="$(printf '%s\n' "${meta_candidates[@]}" | sort | tail -1)"
server="$(sed -n 's/^server=//p' "${artifact_meta}" | tail -1)"
apk="$(sed -n 's/^apk=//p' "${artifact_meta}" | tail -1)"
[[ -x "${server}" ]] || { echo "error: preserved server missing: ${server}" >&2; exit 2; }
[[ -s "${apk}" ]] || { echo "error: preserved APK missing: ${apk}" >&2; exit 2; }
grep -Fqx 'server_provenance=PASS generated-version-build-graph' "${artifact_meta}" || { echo "error: server provenance marker missing" >&2; exit 2; }
grep -Fqx 'artifact_gate=PASS exact-commit-server-and-apk' "${artifact_meta}" || { echo "error: exact artifact gate marker missing" >&2; exit 2; }
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

printf 'source_commit=%s\nartifact_metadata=%s\nserver=%s\napk=%s\napk_sha256=%s\nadb_serial=%s\n' \
    "${source_commit}" "${artifact_meta}" "${server}" "${apk}" "${actual_sha}" "${serial}" >"${out}/metadata.txt"

logcat_pid=""
server_pid=""
active_units=()
cleanup() {
    set +e
    if [[ -n "${server_pid}" ]]; then kill "${server_pid}" >/dev/null 2>&1 || true; fi
    if [[ -n "${logcat_pid}" ]]; then kill "${logcat_pid}" >/dev/null 2>&1 || true; fi
    "${adbq[@]}" shell am force-stop "${package}" >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null 2>&1; then
        for unit in "${active_units[@]}"; do systemctl --user start "${unit}" >/dev/null 2>&1 || true; done
    fi
}
trap cleanup EXIT INT TERM

echo "[1/8] Verifying Quest is awake before touching runtime"
"${adbq[@]}" shell dumpsys power >"${out}/power-before.txt"
if ! grep -Eq 'mWakefulness=Awake|Wakefulness: Awake' "${out}/power-before.txt"; then
    echo "error: Quest is not awake; put the headset on/wake it, then rerun this gate" >&2
    exit 2
fi

echo "[2/8] Installing exact matching Quest APK without erasing app data"
set +e
"${adbq[@]}" install -r -d "${apk}" 2>&1 | tee "${out}/adb-install.txt"
install_status=${PIPESTATUS[0]}
set -e
(( install_status == 0 )) || { echo "error: adb install failed; APK was not uninstalled, pairing state preserved" >&2; exit "${install_status}"; }
"${adbq[@]}" shell dumpsys package "${package}" >"${out}/package.txt"
grep -Fq "versionName=${version_name}" "${out}/package.txt" || { echo "error: installed package version does not match ${version_name}" >&2; exit 2; }

echo "[3/8] Deriving Quest and host transport addresses"
quest_ip="$("${adbq[@]}" shell ip -4 addr show wlan0 | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1 | tr -d '\r')"
[[ -n "${quest_ip}" ]] || { echo "error: could not determine Quest wlan0 IPv4 address" >&2; exit 2; }
host_ip="$(ip -4 route get "${quest_ip}" | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[[ -n "${host_ip}" ]] || { echo "error: could not determine host route address to Quest" >&2; exit 2; }
printf 'quest_ip=%s\nhost_ip=%s\n' "$quest_ip" "$host_ip" | tee "${out}/route.txt" >>"${out}/metadata.txt"

if command -v systemctl >/dev/null 2>&1; then
    mapfile -t active_units < <(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk 'tolower($1) ~ /wivrn/ {print $1}')
    for unit in "${active_units[@]}"; do
        echo "Stopping active user unit ${unit} for isolated promotion run" | tee -a "${out}/preflight.txt"
        systemctl --user stop "${unit}" || true
    done
fi
mapfile -t old_pids < <(pgrep -u "${UID}" -x wivrn-server 2>/dev/null || true)
if [[ "${#old_pids[@]}" -gt 0 ]]; then
    printf 'Stopping existing user wivrn-server PIDs: %s\n' "${old_pids[*]}" | tee -a "${out}/preflight.txt"
    kill -TERM "${old_pids[@]}" 2>/dev/null || true
    for _ in {1..20}; do sleep 0.1; pgrep -u "${UID}" -x wivrn-server >/dev/null 2>&1 || break; done
fi
pgrep -u "${UID}" -x wivrn-server >/dev/null 2>&1 && { echo "error: existing wivrn-server still running" >&2; exit 2; }

echo "[4/8] Starting Quest log capture"
"${adbq[@]}" logcat -c
"${adbq[@]}" logcat -v threadtime >"${out}/quest-logcat.txt" 2>&1 &
logcat_pid=$!

echo "[5/8] Starting exact torture server"
set +e
timeout --signal=TERM --kill-after=5s 180s "${server}" --helix-synthetic-transport >"${out}/server.log" 2>&1 &
server_pid=$!
set -e
sleep 2
kill -0 "${server_pid}" 2>/dev/null || { echo "error: torture server exited before Quest launch" >&2; tail -80 "${out}/server.log" >&2; exit 2; }

echo "[6/8] Launching Quest directly at host torture server"
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

echo "[7/8] Reducing fixed 95/5 promotion gate"
set +e
python3 - "$server_status" "${out}/server.log" "${out}/quest-logcat.txt" "${out}/result.txt" <<'PY'
import re, sys
from pathlib import Path
server_status=int(sys.argv[1])
server=Path(sys.argv[2]).read_text(errors='replace')
quest=Path(sys.argv[3]).read_text(errors='replace')
out=Path(sys.argv[4])
lines=re.findall(r'^.*HELIX_SYNTHETIC_TRANSPORT_RESULT.*$', server, re.M)
exit_lines=re.findall(r'^.*HELIX_SYNTHETIC_TRANSPORT_EXIT.*$', server, re.M)

quest_fatal = bool(re.search(r'Fatal signal\s+\d+.*(?:meu\.wivrn\.local|pid\s+\d+)', quest, re.I))
quest_abort = bool(re.search(r'Abort message:.*(?:org\.meumeu\.wivrn\.local|client/scenes/stream\.cpp|assertion)', quest, re.I))
quest_process_abort = bool(re.search(r'Process\s+org\.meumeu\.wivrn\.local.*(?:died|signal\s+6|Aborted)', quest, re.I|re.S))
quest_crash = quest_fatal or quest_abort or quest_process_abort

if not lines or not exit_lines:
    report=[
        'verdict=FAIL',
        'reason=missing_authoritative_transport_result_or_exit',
        f'quest_crash={int(quest_crash)}',
        f'server_status={server_status}',
    ]
    out.write_text('\n'.join(report)+'\n')
    print(out.read_text(), end='')
    raise SystemExit(1)

# If both the framework logger and deterministic stderr path are visible, they
# are semantically identical. Parse the last one and also require all visible
# result lines to agree exactly after the marker.
normalized=[line.split('HELIX_SYNTHETIC_TRANSPORT_RESULT',1)[1].strip() for line in lines]
if len(set(normalized)) != 1:
    out.write_text('verdict=FAIL\nreason=inconsistent_duplicate_transport_results\n')
    print(out.read_text(), end='')
    raise SystemExit(1)
result=lines[-1]
exit_line=exit_lines[-1]
kv={k:v for k,v in re.findall(r'\b([A-Za-z_]+)=([0-9.]+)\b', result)}
def i(k): return int(kv.get(k,'-1'))
def f(k): return float(kv.get(k,'-1'))
failed_total=max(0, i('total')-i('good'))
failed_lines=re.findall(r'^.*(?:HELIX_SYNTHETIC_TRANSPORT_CASE_FAILED|Helix synthetic transport case failed).*$', server, re.M)
# Framework + direct stderr may duplicate failure diagnostics. Deduplicate by
# the deterministic state tuple rather than by literal line prefix.
failed_states=[]
for line in failed_lines:
    vals={k:int(v) for k,v in re.findall(r'\b(stream|base|missing|start|damaged_ok|exposing_ok|gap_ok)=(\d+)\b', line)}
    if all(k in vals for k in ('stream','base','missing','start','damaged_ok','exposing_ok','gap_ok')):
        failed_states.append(tuple(vals[k] for k in ('stream','base','missing','start','damaged_ok','exposing_ok','gap_ok')))
failed_states=list(dict.fromkeys(failed_states))
clean_failed=sum(1 for s in failed_states if s[4] == 1 and s[5] == 1)
dirty_failed=sum(1 for s in failed_states if not (s[4] == 1 and s[5] == 1))
ordering_failed=max(0, i('ordering_total')-i('ordering_good'))
rtx_failed=max(0, i('rtx_total')-i('rtx_good'))
classified=(len(failed_states)==failed_total)
good_ratio=f('good_ratio')
recovery_share=(clean_failed / i('total')) if i('total') > 0 else 1.0
hard_floor = good_ratio >= 0.95
strong = good_ratio >= 0.98
clean_remainder = classified and dirty_failed == 0 and recovery_share <= 0.05
auxiliary = (f('fallback_ratio') >= 0.95 and f('recorded_ratio') >= 0.95 and f('envelope_ratio') >= 0.95 and f('ordering_ratio') >= 0.95 and f('rtx_ratio') >= 0.95)
no_unclassified_aux = ordering_failed == 0 and rtx_failed == 0
no_hard = i('catastrophic') == 0 and not quest_crash and server_status == 0 and 'result=0' in exit_line and i('pass') == 1
passed = hard_floor and clean_remainder and auxiliary and no_unclassified_aux and no_hard
label = 'STRONG_PASS_98_PLUS' if passed and strong else ('PASS_95_FLOOR' if passed else 'FAIL')
report=[
    f'verdict={label}',
    f'good_ratio={good_ratio:.6f}',
    f'good={i("good")}/{i("total")}',
    f'failed_total={failed_total}',
    f'clean_recovery_failed={clean_failed}',
    f'dirty_recovery_failed={dirty_failed}',
    f'recovery_share={recovery_share:.6f}',
    f'failure_states_classified={len(failed_states)}/{failed_total}',
    f'ordering_failed={ordering_failed}',
    f'rtx_failed={rtx_failed}',
    f'fallback_ratio={f("fallback_ratio"):.6f}',
    f'recorded_ratio={f("recorded_ratio"):.6f}',
    f'envelope_ratio={f("envelope_ratio"):.6f}',
    f'ordering_ratio={f("ordering_ratio"):.6f}',
    f'rtx_ratio={f("rtx_ratio"):.6f}',
    f'catastrophic={i("catastrophic")}',
    f'quest_crash={int(quest_crash)}',
    f'quest_fatal_signal={int(quest_fatal)}',
    f'quest_abort_message={int(quest_abort)}',
    f'quest_process_abort={int(quest_process_abort)}',
    f'server_status={server_status}',
    result,
    exit_line,
]
out.write_text('\n'.join(report)+'\n')
print(out.read_text(), end='')
raise SystemExit(0 if passed else 1)
PY
reduce_status=$?
set -e

echo "[8/8] Final verdict"
if (( reduce_status == 0 )); then
    grep '^verdict=' "${out}/result.txt"
    printf 'PASS: >=95%% good with <=5%% classified clean recovery, zero dirty/unclassified ordering/RTX failures, and no hard failure markers.\n'
else
    printf 'FAIL: fixed 95/5 promotion gate not cleared. Evidence preserved; do not rerun until failure class is audited.\n'
fi
printf 'evidence=%s\n' "${out}"
exit "${reduce_status}"
