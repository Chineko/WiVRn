#!/usr/bin/env python3
"""Separate SGSR1 comparison app; sealed server, capture until Ctrl+C."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

BASE=Path(__file__).resolve().parent
PACKAGE='org.meumeu.wivrn.sgsr1'
ORIGINAL='org.meumeu.wivrn.local'
def digest(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
def adb(serial,*args,data=None):
    return subprocess.run(['/usr/bin/adb','-s',serial,*args],input=data,
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True,timeout=90).stdout
def write_private(serial,path,data):
    assert path in ('files/client.json','files/private_key.pem')
    adb(serial,'shell','run-as',PACKAGE,'sh','-c',f"'umask 077; cat > {path}.tmp'",data=data)
    if adb(serial,'shell','run-as',PACKAGE,'cat',path+'.tmp')!=data:
        raise RuntimeError('private file verification failed; destination preserved')
    adb(serial,'shell','run-as',PACKAGE,'mv',path+'.tmp',path)
    if adb(serial,'shell','run-as',PACKAGE,'cat',path)!=data:
        raise RuntimeError('private file final verification failed')

def main():
    global BASE
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['sgsr1','meta','bilinear'],default='sgsr1')
    parser.add_argument('--sharpening',type=int,choices=range(101),metavar='0..100',default=75)
    parser.add_argument('--seconds',type=int,default=0,help='0 means capture until Ctrl+C')
    parser.add_argument('--vibrance',type=int,choices=range(101),metavar='0..100',default=None,help='preserve saved value if omitted')
    parser.add_argument('--capture-dir',type=Path,required=True,help='directory containing frozen capture harness, bundles and seals')
    args=parser.parse_args()
    BASE=args.capture_dir.resolve(strict=True)
    if args.seconds<0: parser.error('--seconds must be nonnegative')
    seal=json.loads((BASE/'sgsr1-vibrance/seal.json').read_text())
    apk=Path(seal['apk'])
    if digest(apk)!=seal['apk_sha256']: raise RuntimeError('comparison APK changed')
    capture=load('comparison_capture',BASE/'vrchat-capture-wireless-udpdiag-fixed-gpuproc.py')
    if digest(capture.__file__)!='f3ac8bb443307f60a1316eca12289db33664a90e19eb03dd896893375c65902e':
        raise RuntimeError('audited capture harness changed')
    import vrchat_extent_probe
    vrchat_extent_probe.check_artifacts()
    original_verify=capture.r.verify_seal
    def verify(bundle):
        verified=original_verify(bundle) # all original artifact gates remain
        if digest(apk)!=seal['apk_sha256']: raise RuntimeError('comparison APK changed')
        return {**verified,'apk':str(apk),'client_source_commit':seal['client_source_commit']}
    capture.r.verify_seal=verify
    capture.r.PACKAGE=PACKAGE
    names=capture.r.command(['ps','-eo','comm='])
    if any(n.strip() in ('wivrn-server','wivrn-dashboard','VRChat.exe') for n in names.splitlines()):
        raise RuntimeError('Existing session; preserve it')
    _,serial=capture.preflight()
    adb(serial,'install','-r',str(apk))
    adb(serial,'shell','am','force-stop',PACKAGE)
    adb(serial,'shell','run-as',PACKAGE,'mkdir','-p','files')
    # Seed pairing identity only on first use. No key bytes printed or saved on host.
    exists=subprocess.run(['/usr/bin/adb','-s',serial,'shell','run-as',PACKAGE,'test','-f','files/private_key.pem'],timeout=30).returncode==0
    try:
        config=json.loads(adb(serial,'shell','run-as',PACKAGE,'cat','files/client.json'))
    except subprocess.CalledProcessError:
        config=json.loads(adb(serial,'shell','run-as',ORIGINAL,'cat','files/client.json'))
    key=adb(serial,'shell','run-as',ORIGINAL,'cat','files/private_key.pem') if not exists else None
    if args.vibrance is not None:
        config['vibrance']=args.vibrance
    config.setdefault('vibrance',0)
    config['sgsr1_enabled']=args.mode=='sgsr1'
    config['sgsr1_sharpening']=args.sharpening
    post=config.setdefault('openxr_post_processing',{})
    post['sharpening']=8 if args.mode=='meta' else 0
    post['super_sampling']=0
    encoded=json.dumps(config,separators=(',',':')).encode()
    write_private(serial,'files/client.json',encoded)
    if key is not None:
        write_private(serial,'files/private_key.pem',key)
    saved=capture.r.save
    def save(path,value):
        if Path(path).name=='input-seal.json':
            (Path(path).parent/'comparison-launcher-source.py').write_text(Path(__file__).read_text())
        if Path(path).name=='result.json' and isinstance(value,dict) and value.get('mode')=='real VRChat observational capture':
            value.update(client_source_commit=seal['client_source_commit'],client_apk_sha256=seal['apk_sha256'],
                         requested_comparison_mode=args.mode,requested_sgsr1_sharpening_percent=args.sharpening,requested_vibrance_percent=config['vibrance'])
        saved(path,value)
    capture.r.save=save
    print(f'Comparison mode={args.mode}, SGSR1 sharpening={args.sharpening}%. Ctrl+C saves capture.',flush=True)
    return capture.run(args.seconds)
if __name__=='__main__':
    try: sys.exit(main())
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as exc:
        print('Stopped:',exc,file=sys.stderr);sys.exit(2)
