#!/usr/bin/env python3
"""Mutation tests for the formal both-eye oracle; no device required."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('helix-vrchat-encoded.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

def fixture():
    s, q = [], []
    for eye in (0, 1):
        f, seq = 1000 + eye, 2000 + eye
        s += [f'HELIX_HEVC10_ENCODER_GATE stream={eye} encoder=nvenc codec=h265 bit_depth=10',
              f'HELIX_HEVC10_MAIN10_PROFILE stream={eye} profile=main10 input_bit_depth=10 output_bit_depth=10',
              f'HELIX_HEVC10_DROP stream={eye} ordinal={600 if eye == 0 else 900} frame={f} shard=0 packet_sequence={seq} cached=1',
              f'HELIX_HEVC10_RTX_SENT stream={eye} frame={f} packet_sequence={seq} exact_canary=1',
              f'HELIX_PATH_RTX_DELIVERED stream={eye} frame={f} packet_sequence={seq}',
              f'HELIX_HEVC10_FAULT_SUMMARY stream={eye} injected=1 exact_rtx_sent=1 pending_sequence=no',
              f'Helix pacing baseline stream {eye}: frames=27000 frame_bytes(avg/max)=30000/60000 inter_frame_gap(avg/max)=11111/80000us']
        q += [f'HELIX_HEVC10_PROBE_EPOCH stream={eye} epoch=1',
              f'HELIX_HEVC10_RTX_RECEIVED stream={eye} frame={f} packet_sequence={seq} shard=0',
              f'HELIX_HEVC10_RTX_ASSEMBLED stream={eye} frame={f}',
              f'HELIX_HEVC10_RTX_MEDIA_OUTPUT stream={eye} frame={f} exact_recovered_frame=1',
              f'HELIX_HEVC10_IMAGE_AFTER_RTX stream={eye} recovered_frame={f} image_frame={f+1}',
              f'HELIX_HEVC10_PROBE_SUMMARY stream={eye} overflow=0']
    s += ['HELIX_PATH_SUMMARY sent=999 dropped0=50 dropped1=55 delayed0=100 delayed1=100 failed=0 canceled=0 late_max_us=50']
    return '\n'.join(s), '\n'.join(q), 'HELIX_VULKAN_DONE frames=27000 attempts=27001', {
        'frame_count': 27000, 'calibration': {'frame_bytes_mean': 30000, 'frame_bytes_max': 60000, 'fps': 90}}

class Oracle(unittest.TestCase):
    def test_valid_exact_chain(self):
        self.assertEqual(runner.reduce(*fixture())['overall'], 'PASS')

    def test_mutations_cannot_pass(self):
        s, q, v, m = fixture()
        mutations = [
            (s, q.replace('packet_sequence=2001', 'packet_sequence=2000'), v),
            (s, q.replace('frame=1001 exact_recovered_frame=1', 'frame=1002 exact_recovered_frame=1'), v),
            (s, q.replace('HELIX_HEVC10_RTX_MEDIA_OUTPUT', 'sent_to_decoder'), v),
            (s, q.replace('overflow=0', 'overflow=1'), v),
            (s, q.replace('image_frame=1002', 'image_frame=999'), v),
            (s, q.replace('epoch=1', 'epoch=2'), v),
            (s.replace('canceled=0', 'canceled=1'), q, v),
            (s.replace('late_max_us=50', 'late_max_us=3001'), q, v),
            (s.replace('profile=main10', 'profile=main'), q, v),
            (s, q + '\nHELIX_HEVC10_RTX_MEDIA_OUTPUT stream=1 frame=1001 exact_recovered_frame=1', v),
            (s, q + '\nHELIX_HEVC10_PROBE_INVALIDATED stream=1 reason=flush', v),
            (s, q, v.replace('frames=27000', 'frames=26999')),
        ]
        for i, (a, b, c) in enumerate(mutations):
            with self.subTest(i=i):
                self.assertEqual(runner.reduce(a, b, c, m)['runtime'], 'FAIL')

    def test_realism_separate_from_decoder(self):
        s, q, v, m = fixture()
        r = runner.reduce(s.replace('30000/60000', '10000/60000'), q, v, m)
        self.assertEqual(r['hevc10_recovery'], 'PASS')
        self.assertEqual(r['traffic_calibration'], 'NOT_ESTABLISHED')
        self.assertEqual(r['overall'], 'NOT_ESTABLISHED')

    def test_order_is_per_process(self):
        s, q, v, m = fixture()
        lines = q.splitlines()
        a = next(i for i,x in enumerate(lines) if 'RTX_ASSEMBLED stream=0' in x)
        b = next(i for i,x in enumerate(lines) if 'RTX_MEDIA_OUTPUT stream=0' in x)
        lines[a], lines[b] = lines[b], lines[a]
        self.assertEqual(runner.reduce(s, '\n'.join(lines), v, m)['runtime'], 'FAIL')


    def test_production_coverage_is_required(self):
        s, q, v, m = fixture()
        m["producer_stalls"] = [(15000000, 15050000)]
        m["idr_count"] = 1
        s += "\nHELIX_PRODUCER_STALL_BEGIN index=0 at_us=15000010 end_us=15050000\nHELIX_PRODUCER_STALL_END index=0 at_us=15050010 observed=1\nHELIX_PRODUCER_IDR count=1 at_us=15050010"
        for eye in (0, 1):
            s += f"\nHELIX_ENCODED_IDR stream={eye} frame=1 bytes=60000\nHELIX_ENCODED_IDR stream={eye} frame=2 bytes=60000"
        self.assertEqual(runner.reduce(s,q,v,m)["overall"], "PASS")
        self.assertEqual(runner.reduce(s.replace("observed=1","observed=0"),q,v,m)["runtime"], "FAIL")
        self.assertEqual(runner.reduce(s.replace("HELIX_ENCODED_IDR","REQUEST_ONLY"),q,v,m)["runtime"], "FAIL")

if __name__ == '__main__':
    unittest.main()
