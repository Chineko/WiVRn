#!/usr/bin/fish
# Exact tested source and sealed bundle; runner enforces identities and audit gates.
set -l result_dir /home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-v2-repeat-(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
/usr/bin/python3 /home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn/tools/helix-vrchat-encoded.py run --bundle /home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-stimulus-v2 --output $result_dir
set -l run_status $status
printf 'Result: %s/result.json\n' $result_dir
exit $run_status
