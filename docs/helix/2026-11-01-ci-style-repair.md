# CI style/lint repair

The Format workflow failed at 5217eae3626497efad3d50a5a947c0153ae557b0: Ruff lint and client/server clang-format. These are source-style/tooling failures, not new runtime failures. The full failure class included older Helix Python helper permissions/imports, unused locals, loop-variable binding, file-handle management and broad CLI/cleanup exception boundaries.

Reproduced with Ruff 0.16.0 and clang-format 22.1.8, matching CI version requirements. Existing lint rules and workflow scopes remain unchanged. C++ edits are exactly formatter output. Python scripts with shebangs are executable; imports are sorted, unused locals removed, loop captures bound, files closed, and broad boundary catches retain cleanup behavior with named exception logging. Existing source-transform rollback/rethrow paths are preserved.

Validation: Ruff check and format --check PASS; all five C++ workflow scopes PASS; six exact-oracle reducer tests PASS. Before/after generated model, trace, frame/path/production plans and seals are byte-identical for seed 20261031. Both retained device-run reductions are unchanged. The large diff is bounded to formatter output and the listed lint corrections; no unrelated refactor or threshold change. No new device run or rebuilt-artifact claim is made. Native artifacts remain tied to tested source 34f7b98b372d42c1c8f4b6bc17ecd0c0784a609a. Exact-source runtime gates must not be bypassed for this successor.

Rule 40: direct evidence establishes style failures and local reproduction/fixes; remote CI confirmation is separate. Existing recovery PASS and repeat-calibration NOT_ESTABLISHED remain unchanged. Full runtime Audit A/B must be renewed on any newly built successor before device testing; current runtime gate remains CLOSED.
