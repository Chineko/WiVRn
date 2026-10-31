#!/usr/bin/env python3
"""Prepare, seal, run and reduce the opt-in real HEVC10 representative lane.

All paths are explicit or resolved relative to this file, never the caller's cwd.
No dashboard, shell prefix, root, traffic redirection, or external Python packages.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'org.meumeu.wivrn.local'
ACTIVITY = 'org.meumeu.wivrn.MainActivity'
HOST = '192.168.0.44'
QUEST = '192.168.0.54'

def require(value, message):
    if not value:
        raise RuntimeError(message)

def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def command(args, *, output=None, timeout=30, env=None):
    # Lists only: no shell interpolation or pipefail/SIGPIPE hazards.
    if output:
        with Path(output).open('w') as f:
            subprocess.run([str(x) for x in args], check=True, stdout=f,
                           stderr=subprocess.STDOUT, timeout=timeout, env=env, cwd=ROOT)
        return ''
    return subprocess.check_output([str(x) for x in args], text=True, stderr=subprocess.STDOUT,
                                   timeout=timeout, env=env, cwd=ROOT)

def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')

def absolute(value):
    path = Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError('an absolute path is required')
    return path.resolve()

def model():
    spec = importlib.util.spec_from_file_location('helix_model', ROOT / 'tools/helix-vrchat-workload-model.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def prepare(out, pacing_log, seed, encoder_bitrate):
    require(4_000_000 <= encoder_bitrate <= 200_000_000, 'encoder bitrate outside bounded range')
    m = model()
    cal = m.parse_pacing_log(pacing_log)
    # The old parser leaves shards_mean at its unrelated default. Use the actual
    # measured totals rather than integer-truncated frame_shards(avg/max) text.
    measured = re.findall(r'Helix pacing baseline stream [01]:.*?frames=(\d+) payload_bytes=\d+ shards=(\d+)', pacing_log.read_text())
    require(len(measured) == 2, 'one measured pacing epoch per eye is required')
    cal['shards_mean'] = sum(int(shards) for frames, shards in measured) / sum(int(frames) for frames, shards in measured)
    # Explicit new lane parameter: reserve 15 seconds for isolated decoder canaries.
    cal['warmup_s'] = 15.0
    tr = m.generate(seed, 300, 'torture', cal)
    stats = m.stats(tr, cal)
    require(not m.calibration_failures(stats, cal), 'model calibration gate failed')
    require(tr['events'] and tr['stall_spans'], 'seed lacks path events/producer stalls')
    events = [e for e in tr['events'] if e['e'] < 300_000_000]
    require(events, 'no bounded events')
    out.mkdir(parents=True, exist_ok=False)
    (out / 'path.plan').write_text('HELIX_ENCODED_PLAN 1\n300000000\n' +
        ''.join(f'{e["s"]} {e["s"] + e["L"]} {e["e"]}\n' for e in events))
    eyes = {s: [x for x in tr['frame_meta'] if x[0] == s] for s in (0, 1)}
    require(len(eyes[0]) == len(eyes[1]), 'eye schedule length mismatch')
    # Production times are shared; natural encoder/compositor eye offset is measured,
    # not fabricated by claiming exact replay of independent eye completion times.
    (out / 'frames.plan').write_text('HELIX_ENCODED_FRAMES 1\n' + ''.join(
        f'{a[4]} {a[2]} {b[2]}\n' for a, b in zip(eyes[0], eyes[1])))
    idrs = [a[4] for a in eyes[0] if a[5]]
    (out / 'production.plan').write_text('HELIX_ENCODED_PRODUCTION 1\n' +
        ''.join(f'S {start} {end}\n' for start, end in tr['stall_spans']) +
        ''.join(f'I {at}\n' for at in idrs))
    m.write_trace(tr, out / 'model.trace')
    shutil.copyfile(pacing_log, out / 'calibration-source.log')
    stats.update({'seed': seed, 'duration_s': 300, 'profile': 'torture', 'calibration': cal,
                  'path_events': events, 'producer_stalls': tr['stall_spans'],
                  'source_log': str(pacing_log), 'source_log_sha256': digest(pacing_log),
                  'warmup_override_s': 15, 'frame_count': len(eyes[0]),
                  'encoder_bitrate_bps': encoder_bitrate, 'idr_count': len(idrs),
                  'limitations': ['content complexity is a deterministic surrogate',
                    'actual encoded sizes/cadence must pass a separate runtime calibration gate',
                    'shared path event shapes/drain priors retain the existing model assumptions',
                    'not a reproduction of VRChat CPU, avatar, or GPU rendering cost']})
    save(out / 'model.json', stats)
    save(out / 'plan-seal.json', {p.name: digest(p) for p in sorted(out.iterdir()) if p.is_file()})
    return stats

def build(bundle, build_dir):
    require(not command(['git', '-C', ROOT, 'status', '--porcelain']).strip(), 'commit the audited implementation before building')
    commit = command(['git', '-C', ROOT, 'rev-parse', 'HEAD']).strip()
    plan_seal = json.loads((bundle / 'plan-seal.json').read_text())
    for name, sha in plan_seal.items():
        require(digest(bundle / name) == sha, 'plan identity changed: ' + name)
    cache = (build_dir / 'CMakeCache.txt').read_text()
    require(f'CMAKE_HOME_DIRECTORY:INTERNAL={ROOT}\n' in cache, 'build tree belongs to different source')
    command(['ninja', '-C', build_dir, '-t', 'query', 'openxr_wivrn'], output=bundle / 'ninja-query.txt')
    command(['cmake', '--build', build_dir, '--target', 'wivrn-server', 'openxr_wivrn', '-j', '2'],
            output=bundle / 'build-server.log', timeout=1200)
    command(['c++', '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
             ROOT / 'tools/helix-vrchat-encoded-stimulus.cpp', '-lopenxr_loader', '-lvulkan', '-pthread',
             '-o', bundle / 'stimulus'], output=bundle / 'build-stimulus.log', timeout=60)
    env = os.environ.copy()
    env.update(ANDROID_HOME='/opt/android-sdk', JAVA_HOME='/usr/lib/jvm/java-17-openjdk')
    env.pop('ANDROID_SDK_ROOT', None)
    command(['/usr/lib/jvm/java-17-openjdk/bin/java', '-classpath', ROOT / 'gradle/wrapper/gradle-wrapper.jar',
             'org.gradle.wrapper.GradleWrapperMain', '--project-dir', ROOT, '--offline', '--no-daemon',
             '--max-workers=2', 'assembleDebug', '-Pwivrn_version=helix-encoded-' + commit],
            output=bundle / 'build-apk.log', timeout=1800, env=env)
    (bundle / 'server').mkdir(exist_ok=True)
    (bundle / 'runtime').mkdir(exist_ok=True)
    shutil.copy2(build_dir / 'server/wivrn-server', bundle / 'server/wivrn-server')
    shutil.copy2(ROOT / 'build/outputs/apk/debug/WiVRn-debug.apk', bundle / 'client.apk')
    manifest = json.loads((build_dir / 'openxr_wivrn-dev.json').read_text())
    require(manifest.get('file_format_version') == '1.0.0', 'manifest version mismatch')
    lib = Path(manifest['runtime']['library_path']).resolve(strict=True)
    require(lib.name == 'libopenxr_wivrn.so' and lib.is_relative_to(build_dir), 'wrong runtime ELF')
    shutil.copy2(lib, bundle / 'runtime/libopenxr_wivrn.so')
    monado = Path(manifest['runtime']['MND_libmonado_path']).resolve(strict=True)
    require(monado.is_relative_to(build_dir), 'ancillary library escapes build tree')
    shutil.copy2(monado, bundle / 'runtime/libmonado_wivrn.so')
    manifest['runtime']['library_path'] = str(bundle / 'runtime/libopenxr_wivrn.so')
    manifest['runtime']['MND_libmonado_path'] = str(bundle / 'runtime/libmonado_wivrn.so')
    save(bundle / 'openxr_wivrn-dev.json', manifest)
    elf = bundle / 'runtime/libopenxr_wivrn.so'
    header = command(['readelf', '-h', elf])
    symbols = command(['nm', '-D', '--defined-only', elf])
    require('Advanced Micro Devices X86-64' in header and ' T xrNegotiateLoaderRuntimeInterface' in symbols, 'runtime architecture/export mismatch')
    (bundle / 'elf-audit.txt').write_text(header + symbols)
    import zipfile
    with zipfile.ZipFile(bundle / 'client.apk') as z:
        require(z.testzip() is None, 'APK CRC failure')
        native = z.read('lib/arm64-v8a/libwivrn.so')
        require(commit.encode() in native and b'HELIX_HEVC10_RTX_RECEIVED' in native and b'HELIX_HEVC10_PROBE_EPOCH' in native, 'APK native provenance/probes absent')
    require(commit.encode() in (bundle / 'server/wivrn-server').read_bytes(), 'server source identity absent')
    paths = [p for p in bundle.rglob('*') if p.is_file() and p.name not in ('seal.json', 'audits.json')]
    artifacts = {str(p): digest(p) for p in paths}
    artifacts[str(ROOT / 'tools/helix-vrchat-encoded.py')] = digest(ROOT / 'tools/helix-vrchat-encoded.py')
    for path, sha in artifacts.items():
        require(command(['sha256sum', path]).split()[0] == sha, 'independent hash mismatch: ' + path)
    save(bundle / 'seal.json', {'source_commit': commit, 'server': str(bundle / 'server/wivrn-server'),
         'apk': str(bundle / 'client.apk'), 'stimulus': str(bundle / 'stimulus'),
         'runtime_elf': str(elf), 'manifest': str(bundle / 'openxr_wivrn-dev.json'), 'artifacts': artifacts})
    print('BUILD_AND_SEAL=PASS; runtime remains gated by full Audit A/B')

def events(text, tag):
    return [dict(re.findall(r'\b([A-Za-z_0-9]+)=([^\s]+)', line))
            for line in text.splitlines() if tag + ' ' in line]

def reduce(server, quest, stimulus, spec):
    errors = []
    def check(ok, label):
        if not ok: errors.append(label)
    evidence = {}
    stalls = spec.get('producer_stalls', [])
    begins = events(server, 'HELIX_PRODUCER_STALL_BEGIN')
    ends = events(server, 'HELIX_PRODUCER_STALL_END')
    check(len(begins) == len(ends) == len(stalls), 'production_stall_count')
    for i, (start, end) in enumerate(stalls):
        b = [x for x in begins if x.get('index') == str(i)]
        e = [x for x in ends if x.get('index') == str(i)]
        check(len(b) == len(e) == 1 and start <= int(b[0].get('at_us', '-1')) < end and
              int(e[0].get('at_us', '-1')) >= end and e[0].get('observed') == '1', f'production_stall_{i}')
    check(sum(int(x.get('count', '0')) for x in events(server, 'HELIX_PRODUCER_IDR')) == spec.get('idr_count', 0), 'production_idr_requests')
    for eye in (0, 1):
        select = lambda tag: [e for e in events(server, tag) if e.get('stream') == str(eye)]
        qselect = lambda tag: [e for e in events(quest, tag) if e.get('stream') == str(eye)]
        check(any(e.get('encoder') == 'nvenc' and e.get('codec') == 'h265' and e.get('bit_depth') == '10'
                  for e in select('HELIX_HEVC10_ENCODER_GATE')), f'eye{eye}:encoder_gate')
        check(any(e.get('profile') == 'main10' and e.get('input_bit_depth') == '10' and e.get('output_bit_depth') == '10'
                  for e in select('HELIX_HEVC10_MAIN10_PROFILE')), f'eye{eye}:main10')
        if spec.get('idr_count', 0):
            check(len(select('HELIX_ENCODED_IDR')) >= spec['idr_count'] + 1, f'eye{eye}:actual_idr_coverage')
        drop = select('HELIX_HEVC10_DROP')
        check(len(drop) == 1, f'eye{eye}:unique_canary_drop')
        if len(drop) == 1:
            frame, seq = drop[0].get('frame'), drop[0].get('packet_sequence')
            check(drop[0].get('ordinal') == str(600 if eye == 0 else 900) and
                  drop[0].get('cached') == '1' and drop[0].get('shard') == '0' and seq != '0', f'eye{eye}:frozen_canary')
            chain = [select('HELIX_HEVC10_RTX_SENT'), select('HELIX_PATH_RTX_DELIVERED'),
                     qselect('HELIX_HEVC10_RTX_RECEIVED'), qselect('HELIX_HEVC10_RTX_ASSEMBLED'),
                     qselect('HELIX_HEVC10_RTX_MEDIA_OUTPUT')]
            for name, rows in zip(('sent', 'delivered', 'received', 'assembled', 'media'), chain):
                match = [r for r in rows if r.get('frame') == frame and
                         (name in ('assembled', 'media') or r.get('packet_sequence') == seq)]
                check(len(match) == 1, f'eye{eye}:exact_{name}')
            images = [r for r in qselect('HELIX_HEVC10_IMAGE_AFTER_RTX') if r.get('recovered_frame') == frame]
            check(len(images) == 1 and int(images[0].get('image_frame', '-1')) >= int(frame), f'eye{eye}:image_after')
            # Establish order within each process; do not compare host/Quest wall clocks.
            for text, tags in ((server, ('HELIX_HEVC10_DROP', 'HELIX_HEVC10_RTX_SENT')),
                               (quest, ('HELIX_HEVC10_RTX_RECEIVED', 'HELIX_HEVC10_RTX_ASSEMBLED', 'HELIX_HEVC10_RTX_MEDIA_OUTPUT', 'HELIX_HEVC10_IMAGE_AFTER_RTX'))):
                positions = []
                for tag in tags:
                    lines = [(i, line) for i, line in enumerate(text.splitlines()) if tag + ' ' in line and
                             re.search(r'\bstream=' + str(eye) + r'\b', line) and
                             re.search(r'\b(?:recovered_frame|frame)=' + frame + r'\b', line)]
                    positions.append(lines[0][0] if len(lines) == 1 else -1)
                check(all(i >= 0 for i in positions) and positions == sorted(set(positions)), f'eye{eye}:event_order')
            evidence[str(eye)] = {'frame': frame, 'packet_sequence': seq, 'images': images}
        epochs = qselect('HELIX_HEVC10_PROBE_EPOCH')
        check(len(epochs) == 1 and epochs[0].get('epoch') == '1', f'eye{eye}:single_decoder_epoch')
        summaries = qselect('HELIX_HEVC10_PROBE_SUMMARY')
        check(len(summaries) == 1 and summaries[0].get('overflow') == '0', f'eye{eye}:probe_summary_overflow')
        faults = select('HELIX_HEVC10_FAULT_SUMMARY')
        check(len(faults) == 1 and faults[0].get('injected') == '1' and faults[0].get('exact_rtx_sent') == '1'
              and faults[0].get('pending_sequence') == 'no', f'eye{eye}:fault_summary')
    paths = events(server, 'HELIX_PATH_SUMMARY')
    check(len(paths) == 1, 'path_summary_missing_or_multiple')
    if len(paths) == 1:
        p = paths[0]
        check(p.get('failed') == p.get('canceled') == '0', 'path_failure_or_canceled')
        for eye in (0, 1):
            check(int(p.get(f'dropped{eye}', '0')) > 0, f'eye{eye}:representative_path_drops')
            check(int(p.get(f'delayed{eye}', '0')) > 0, f'eye{eye}:path_delay_exercised')
        check(int(p.get('late_max_us', '999999')) <= 3000, 'path_scheduler_lateness_over_3ms')
    check(not re.search(r'HELIX_HEVC10_PROBE_INVALIDATED|Fatal signal|FATAL EXCEPTION|ANR in org\.meumeu\.wivrn', quest), 'decoder_epoch_invalidated_or_crash')
    check(f'HELIX_VULKAN_DONE frames={spec["frame_count"]} ' in stimulus, 'stimulus_incomplete')
    # Keep representativeness independently visible. No payload padding/truncation to
    # manufacture encoded-size agreement with the model is permitted.
    calibration = []
    rx = re.compile(r'Helix pacing baseline stream ([01]):.*?frames=(\d+).*?frame_bytes\(avg/max\)=(\d+)/(\d+).*?inter_frame_gap\(avg/max\)=(\d+)/(\d+)us')
    observed = {}
    for match in rx.finditer(server):
        eye, frames, mean, maximum, gap, gap_max = map(int, match.groups())
        if eye in observed: calibration.append(f'eye{eye}:multiple_pacing_epochs')
        observed[eye] = {'frames': frames, 'bytes_mean': mean, 'bytes_max': maximum, 'gap_us': gap, 'gap_max_us': gap_max}
    for eye in (0, 1):
        v = observed.get(eye)
        if not v:
            calibration.append(f'eye{eye}:missing_pacing_summary')
            continue
        c = spec['calibration']
        if abs(v['bytes_mean'] / c['frame_bytes_mean'] - 1) > .04: calibration.append(f'eye{eye}:encoded_mean_not_calibrated')
        if not .75 * c['frame_bytes_max'] <= v['bytes_max'] <= 1.25 * c['frame_bytes_max']: calibration.append(f'eye{eye}:encoded_peak_not_calibrated')
        if abs(v['gap_us'] - 1e6 / c['fps']) > 30: calibration.append(f'eye{eye}:cadence_not_calibrated')
        if not 40_000 <= v['gap_max_us'] <= 212_500: calibration.append(f'eye{eye}:producer_gap_not_representative')
    return {'runtime': 'PASS' if not errors else 'FAIL', 'errors': errors, 'canaries': evidence,
            'traffic_calibration': 'PASS' if not calibration else 'NOT_ESTABLISHED',
            'calibration_errors': calibration, 'observed_pacing': observed,
            'hevc10_recovery': 'PASS' if not errors else 'NOT_ESTABLISHED',
            'pixel_cleanliness': 'NOT_ESTABLISHED',
            'overall': 'PASS' if not errors and not calibration else 'NOT_ESTABLISHED'}

def verify_seal(bundle):
    seal = json.loads((bundle / 'seal.json').read_text())
    commit = command(['git', '-C', ROOT, 'rev-parse', 'HEAD']).strip()
    require(commit == seal['source_commit'], 'source commit mismatch')
    require(not command(['git', '-C', ROOT, 'status', '--porcelain']).strip(), 'source checkout is not clean')
    for path, sha in seal['artifacts'].items():
        require(digest(path) == sha, 'sealed artifact changed: ' + path)
    return seal

def adb(serial, *args, **kw):
    return command(['adb', '-s', serial, *args], **kw)

def wait_for(predicate, seconds, description):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(.2)
    raise RuntimeError('timeout: ' + description)

def descendants(parent):
    pairs = [tuple(map(int, row.split())) for row in command(['ps', '-eo', 'pid=,ppid=']).splitlines()]
    found = {parent}
    for _ in pairs:
        added = {pid for pid, ppid in pairs if ppid in found}
        if added <= found: break
        found |= added
    return found - {parent}

def owned_children(parent, expected):
    # Retain start-time identity so cleanup never signals a recycled PID.
    owned = {}
    for pid in descendants(parent):
        try:
            if Path(f'/proc/{pid}/exe').resolve() == Path(expected).resolve():
                owned[pid] = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
        except FileNotFoundError:
            pass
    return owned

def stop_children(owned, sig):
    for pid, start in owned.items():
        try:
            if Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19] == start:
                os.kill(pid, sig)
        except ProcessLookupError:
            pass
        except FileNotFoundError:
            pass

def run(bundle, out):
    out.mkdir(parents=True, exist_ok=False)
    processes = []
    installed_by_run = False
    serial = None
    server = None
    children = {}
    launched = False
    handles = []
    result = {'runtime': 'NOT_RUN', 'overall': 'BLOCKED', 'pixel_cleanliness': 'NOT_ESTABLISHED'}
    try:
        seal = verify_seal(bundle)
        gate = json.loads((bundle / 'audits.json').read_text())
        require(gate.get('audit_a') == gate.get('audit_b') == 'PASS' and
                gate.get('seal_sha256') == digest(bundle / 'seal.json') and
                digest(gate['report']) == gate['report_sha256'], 'full audits absent or stale')
        save(out / 'input-seal.json', seal)
        for name in ('model.json', 'frames.plan', 'path.plan', 'production.plan', 'audits.json'):
            shutil.copyfile(bundle / name, out / name)
        route = command(['ip', '-4', 'route', 'get', QUEST])
        (out / 'route.txt').write_text(route)
        require('src ' + HOST in route and not re.search(r' dev (?:lo|usb\S*|rndis\S*|adb\S*) ', route), 'LAN route/source mismatch')
        devices = [line.split()[0] for line in command(['adb', 'devices']).splitlines()[1:] if '\tdevice' in line]
        require(len(devices) == 1, 'exactly one authorized Quest required')
        serial = devices[0]
        require(not command(['adb', 'forward', '--list']).strip(), 'ADB forwards present')
        require(not adb(serial, 'reverse', '--list').strip(), 'ADB reverses present')
        wlan = adb(serial, 'shell', 'ip', '-4', 'addr', 'show', 'wlan0')
        (out / 'quest-wlan.txt').write_text(wlan)
        require('inet ' + QUEST + '/' in wlan, 'Quest LAN address mismatch')
        # Refuse a conflicting session rather than killing unrelated processes.
        names = command(['ps', '-eo', 'comm='])
        require(not any(n.strip() in ('wivrn-server', 'wivrn-dashboard') for n in names.splitlines()), 'existing WiVRn process; preserve it and stop preflight')
        apk = Path(seal['apk'])
        def installed_matches():
            try:
                paths = adb(serial, 'shell', 'pm', 'path', PACKAGE).strip().splitlines()
                if len(paths) != 1 or not paths[0].startswith('package:'): return False
                adb(serial, 'pull', paths[0][8:].strip(), out / 'installed.apk', timeout=60)
                return digest(out / 'installed.apk') == digest(apk)
            except subprocess.CalledProcessError:
                return False
        if not installed_matches():
            adb(serial, 'install', '-r', apk, output=out / 'install.txt', timeout=120)
            installed_by_run = True
            require(installed_matches(), 'installed APK bytes do not match seal')
        (out / 'package.txt').write_text(adb(serial, 'shell', 'dumpsys', 'package', PACKAGE))
        config = {'encoder': {'encoder': 'nvenc', 'codec': 'h265'}, 'bit-depth': 10,
                  'tcp-only': False, 'publish-service': 'none', 'application': [],
                  'openvr-compat-path': None}
        save(out / 'config.json', config)
        env = os.environ.copy()
        spec = json.loads((bundle / 'model.json').read_text())
        env.update(HELIX_HEVC10_RECOVERY='1', HELIX_ENCODED_PATH_PLAN=str(bundle / 'path.plan'),
                   HELIX_ENCODED_PRODUCTION_PLAN=str(bundle / 'production.plan'),
                   HELIX_ENCODED_BITRATE_BPS=str(spec['encoder_bitrate_bps']))
        env['XR_RUNTIME_JSON'] = seal['manifest']
        # Logcat is bounded by the run and starts before launch; no global log clear.
        capture = (out / 'quest.log').open('w')
        handles.append(capture)
        logcat = subprocess.Popen(['adb', '-s', serial, 'logcat', '-T', '1', '-v', 'epoch', 'WiVRn:V', 'AndroidRuntime:E', 'libc:E', '*:S'], stdout=capture, stderr=subprocess.STDOUT, cwd=ROOT)
        processes.append(logcat)
        server_log = (out / 'server.log').open('w')
        handles.append(server_log)
        server = subprocess.Popen([seal['server'], '-f', str(out / 'config.json'), '--no-publish-service', '--no-manage-active-runtime'],
                                  env=env, stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True, cwd=ROOT)
        processes.append(server)
        wait_for(lambda: server.poll() is not None or ' starting' in (out / 'server.log').read_text(), 15, 'server startup')
        require(server.poll() is None, 'server exited during startup')
        require(Path(f'/proc/{server.pid}/exe').resolve() == Path(seal['server']).resolve(), 'running server identity mismatch')
        adb(serial, 'shell', 'am', 'force-stop', PACKAGE)
        adb(serial, 'shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', 'wivrn://' + HOST,
            '-n', PACKAGE + '/' + ACTIVITY, output=out / 'launch.txt')
        launched = True
        wait_for(lambda: server.poll() is not None or 'Client connected' in (out / 'server.log').read_text(), 45, 'trusted LAN connection')
        require(server.poll() is None, 'server exited before connection')
        children = owned_children(server.pid, seal['server'])
        require('To pair a new headset use PIN code:' not in (out / 'server.log').read_text(), 'pairing needed; no silent authentication bypass')
        child_env = os.environ.copy()
        child_env['XR_RUNTIME_JSON'] = seal['manifest']
        workload_log = (out / 'stimulus.log').open('w')
        handles.append(workload_log)
        workload = subprocess.Popen([seal['stimulus'], str(bundle / 'frames.plan')], env=child_env, stdout=workload_log, stderr=subprocess.STDOUT, start_new_session=True, cwd=ROOT)
        processes.append(workload)
        # Loaded module proof belongs to the actual OpenXR application, not server ELF.
        wait_for(lambda: workload.poll() is not None or seal['runtime_elf'] in Path(f'/proc/{workload.pid}/maps').read_text(), 15, 'loaded OpenXR ELF')
        require(workload.poll() is None, 'stimulus exited at startup')
        (out / 'stimulus-maps.txt').write_text(Path(f'/proc/{workload.pid}/maps').read_text())
        result['runtime'] = 'RUNNING'
        deadline = time.monotonic() + 345
        while workload.poll() is None:
            require(server.poll() is None and logcat.poll() is None, 'server/capture died')
            require(time.monotonic() < deadline, 'bounded workload timeout')
            time.sleep(.5)
        require(workload.returncode == 0, 'stimulus failed')
        # Server disconnect allows decoder teardown summaries before any force-stop.
        server.send_signal(signal.SIGTERM)
        server.wait(timeout=15)
        wait_for(lambda: all(f'stream={eye}' in '\n'.join(line for line in (out / 'quest.log').read_text().splitlines()
                       if 'HELIX_HEVC10_PROBE_SUMMARY' in line) for eye in (0, 1)), 15, 'decoder summaries')
        logcat.terminate(); logcat.wait(timeout=5)
        for f in (capture, server_log, workload_log): f.close()
        require(verify_seal(bundle) == seal, 'postrun identity mismatch')
        s, q, v = [(out / n).read_text() for n in ('server.log', 'quest.log', 'stimulus.log')]
        require(seal['source_commit'] in q and seal['source_commit'][:8] in s, 'runtime commit provenance missing')
        result = reduce(s, q, v, json.loads((bundle / 'model.json').read_text()))
    except Exception as exc:
        if result['runtime'] != 'NOT_RUN': result['runtime'] = 'FAIL'
        result.update(overall='BLOCKED' if result['runtime'] == 'NOT_RUN' else 'FAIL', error=str(exc))
    finally:
        if server and server.poll() is None:
            children.update(owned_children(server.pid, seal['server']))
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=10)
                except subprocess.TimeoutExpired: p.kill(); p.wait(timeout=5)
        stop_children(children, signal.SIGTERM)
        if children:
            time.sleep(.2)
            stop_children(children, signal.SIGKILL)
        for f in handles:
            f.close()
        # Do not force-stop before collecting graceful teardown evidence.
        if serial and launched:
            try: adb(serial, 'shell', 'am', 'force-stop', PACKAGE)
            except Exception: pass
        result['installed_by_run'] = installed_by_run
        result['rule40'] = {'direct_evidence': 'See retained logs and per-frame reducer evidence',
            'supported_inference': 'No recovery inference is permitted without the exact chain',
            'remaining_ambiguity': 'Pixel contents and VRChat rendering cost are not measured',
            'decision': 'Any failure closes the audit gate; do not retry before full re-audit'}
        save(out / 'result.json', result)
        # Failure resets the full gate, including preflight/capture/retrieval failures.
        if result.get('overall') != 'PASS' and (bundle / 'audits.json').exists():
            shutil.move(bundle / 'audits.json', out / 'invalidated-audits.json')
        save(out / 'evidence-seal.json', {p.name: digest(p) for p in sorted(out.iterdir()) if p.is_file() and p.name != 'evidence-seal.json'})
    print(json.dumps(result, indent=2))
    return 0 if result.get('overall') == 'PASS' else 2

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='action', required=True)
    p = sub.add_parser('prepare')
    p.add_argument('--output', type=absolute, required=True)
    p.add_argument('--pacing-log', type=absolute, required=True)
    p.add_argument('--seed', type=int, default=20261031)
    p.add_argument('--encoder-bitrate', type=int, required=True)
    p = sub.add_parser('run')
    p.add_argument('--bundle', type=absolute, required=True)
    p.add_argument('--output', type=absolute, required=True)
    p = sub.add_parser('build')
    p.add_argument('--bundle', type=absolute, required=True)
    p.add_argument('--build-dir', type=absolute, required=True)
    p = sub.add_parser('reduce')
    for n in ('server', 'quest', 'stimulus', 'model', 'output'):
        p.add_argument('--' + n, type=absolute, required=True)
    a = ap.parse_args()
    if a.action == 'prepare': prepare(a.output, a.pacing_log, a.seed, a.encoder_bitrate); return 0
    if a.action == 'run': return run(a.bundle, a.output)
    if a.action == 'build': build(a.bundle, a.build_dir); return 0
    result = reduce(a.server.read_text(), a.quest.read_text(), a.stimulus.read_text(), json.loads(a.model.read_text()))
    save(a.output, result)
    return 0 if result['overall'] == 'PASS' else 2

if __name__ == '__main__':
    raise SystemExit(main())
