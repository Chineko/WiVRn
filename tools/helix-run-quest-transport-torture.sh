#!/usr/bin/env bash
set -euo pipefail

source_commit="a315a97f9bd39923a5249365f6fef1b73aa5b452"
package="org.meumeu.wivrn.local"
activity="org.meumeu.wivrn.MainActivity"
version_name="helix-${source_commit}"

for cmd in adb grep sed awk sha256sum sort tail head ip timeout pgrep kill; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

out="${HOME}/helix-quest-transport-runtime-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"

mapfile -t server_meta_candidates < <(grep -l "^source_commit=${source_commit}$" "${HOME}"/helix-quest-torture-v2-build-*/metadata.txt 2>/dev/null || true)
[[ "${#server_meta_candidates[@]}" -gt 0 ]] || { echo "error: no preserved torture server build for ${source_commit}" >&2; exit 2; }
server_meta="$(printf '%s\n' "${server_meta_candidates[@]}" | sort | tail -1)"
server="$(sed -n 's/^server=//p' "${server_meta}" | tail -1)"
[[ -x "${server}" ]] || { echo "error: preserved torture server missing: ${server}" >&2; exit 2; }
grep -Fqx 'provenance=PASS generated-version-build-graph' "${server_meta}" || { echo "error: server provenance marker missing" >&2; exit 2; }

mapfile -t apk_meta_candidates < <(grep -l "^source_commit=${source_commit}$" "${HOME}"/helix-quest-apk-${source_commit:0:12}-*/metadata.txt 2>/dev/null || true)
[[ "${#apk_meta_candidates[@]}" -gt 0 ]] || { echo "error: no preserved matching Quest APK for ${source_commit}" >&2; exit 2; }
apk_meta="$(printf '%s\n' "${apk_meta_candidates[@]}" | sort | tail -1)"
apk="$(sed -n 's/^apk=//p' "${apk_meta}" | tail -1)"
[[ -s "${apk}" ]] || { echo "error: preserved Quest APK missing: ${apk}" >&2; exit 2; }
apk_sha_file="$(dirname "${apk_meta}")/apk.sha256"
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

printf 'source_commit=%s\nserver=%s\nserver_metadata=%s\napk=%s\napk_metadata=%s\napk_sha256=%s\nadb_serial=%s\n' \
    "${source_commit}" "${server}" "${server_meta}" "${apk}" "${apk_meta}" "${actual_sha}" "${serial}" >"${out}/metadata.txt"

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

echo "[1/7] Installing exact matching Quest APK without erasing app data"
set +e
"${adbq[@]}" install -r -d "${apk}" 2>&1 | tee "${out}/adb-install.txt"
install_status=${PIPESTATUS[0]}
set -e
(( install_status == 0 )) || { echo "error: adb install failed; APK was not uninstalled, pairing state preserved" >&2; exit "${install_status}"; }

"${adbq[@]}" shell dumpsys package "${package}" >"${out}/package.txt"
grep -Fq "versionName=${version_name}" "${out}/package.txt" || { echo "error: installed package version does not match ${version_name}" >&2; exit 2; }

echo "[2/7] Deriving Quest and host transport addresses"
quest_ip="$("${adbq[@]}" shell ip -4 addr show wlan0 | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1 | tr -d '\r')"
[[ -n "${quest_ip}" ]] || { echo "error: could not determine Quest wlan0 IPv4 address" >&2; exit 2; }
host_ip="$(ip -4 route get "${quest_ip}" | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[[ -n "${host_ip}" ]] || { echo "error: could not determine host route address to Quest" >&2; exit 2; }
printf 'quest_ip=%s\nhost_ip=%s\n' "${quest_ip}" "${host_ip}" | tee "${out}/route.txt" >>"${out}/metadata.txt"

if command -v systemctl >/dev/null 2>&1; then
    mapfile -t active_units < <(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk 'tolower($1) ~ /wivrn/ {print $1}')
    for unit in "${active_units[@]}"; do
        echo "Stopping active user unit ${unit} for isolated torture run" | tee -a "${out}/preflight.txt"
        systemctl --user stop "${unit}" || true
    done
fi

mapfile -t old_pids < <(pgrep -u "${UID}" -x wivrn-server 2>/dev/null || true)
if [[ "${#old_pids[@]}" -gt 0 ]]; then
    printf 'Stopping existing user wivrn-server PIDs: %s\n' "${old_pids[*]}" | tee -a "${out}/preflight.txt"
    kill -TERM "${old_pids[@]}" 2>/dev/null || true
    for _ in {1..20}; do
        sleep 0.1
        pgrep -u "${UID}" -x wivrn-server >/dev/null 2>&1 || break
    done
fi
pgrep -u "${UID}" -x wivrn-server >/dev/null 2>&1 && { echo "error: existing wivrn-server still running" >&2; exit 2; }

echo "[3/7] Starting Quest log capture"
"${adbq[@]}" logcat -c
"${adbq[@]}" logcat -v threadtime >"${out}/quest-logcat.txt" 2>&1 &
logcat_pid=$!

echo "[4/7] Starting exact torture server"
set +e
timeout --signal=TERM --kill-after=5s 180s "${server}" --helix-synthetic-transport >"${out}/server.log" 2>&1 &
server_pid=$!
set -e
sleep 2
kill -0 "${server_pid}" 2>/dev/null || { echo "error: torture server exited before Quest launch" >&2; tail -80 "${out}/server.log" >&2; exit 2; }

echo "[5/7] Launching Quest directly at host torture server"
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

echo "[6/7] Reducing transport torture result"
result_line="$(grep 'HELIX_SYNTHETIC_TRANSPORT_RESULT' "${out}/server.log" | tail -1 || true)"
exit_line="$(grep 'HELIX_SYNTHETIC_TRANSPORT_EXIT' "${out}/server.log" | tail -1 || true)"
printf 'server_status=%s\n%s\n%s\n' "${server_status}" "${result_line}" "${exit_line}" | tee "${out}/result.txt"

crash_hits="$( (grep -E "${package}.*(FATAL|Fatal signal|ANR)" "${out}/quest-logcat.txt" || true) | wc -l )"
printf 'quest_crash_marker_hits=%s\n' "${crash_hits}" | tee -a "${out}/result.txt"

pass=1
[[ "${server_status}" -eq 0 ]] || pass=0
[[ "${result_line}" == *'pass=1'* ]] || pass=0
[[ "${exit_line}" == *'result=0'* ]] || pass=0
[[ "${result_line}" == *'envelope_ratio=1.000000'* || "${result_line}" =~ envelope_ratio=0\.9[5-9] ]] || pass=0
[[ "${result_line}" == *'ordering_ratio=1.000000'* || "${result_line}" =~ ordering_ratio=0\.9[5-9] ]] || pass=0
[[ "${result_line}" == *'rtx_ratio=1.000000'* || "${result_line}" =~ rtx_ratio=0\.9[5-9] ]] || pass=0
[[ "${crash_hits}" -eq 0 ]] || pass=0

echo "[7/7] Final verdict"
if (( pass )); then
    printf 'PASS: real Quest transport torture cleared the 95%% gates with no package crash markers.\n'
else
    printf 'FAIL: real Quest transport torture did not clear all gates. Evidence preserved; do not rerun yet.\n'
fi
printf 'evidence=%s\n' "${out}"
exit $(( pass ? 0 : 1 ))
