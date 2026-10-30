#!/usr/bin/env python3
from pathlib import Path

p = Path('server/helix_synthetic_transport.cpp')
s = p.read_text()
old = '''\tconst bool oracle_ok = oracle_self_test();
\tU_LOG_I("HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d", oracle_ok);
\tif (!oracle_ok)
\t\treturn 2;
'''
new = '''\tconst bool oracle_ok = oracle_self_test();
\tU_LOG_I("HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d", oracle_ok);
\tstd::fprintf(stderr, "HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d\\n", oracle_ok);
\tstd::fflush(stderr);
\tif (!oracle_ok)
\t\treturn 2;
'''
count = s.count(old)
if count != 1:
    raise SystemExit(f'FAIL: oracle sanity anchor count={count}')
s = s.replace(old, new, 1)
p.write_text(s)
print('PROMOTION_TRANSFORM=PASS deterministic oracle sanity stderr marker added')
