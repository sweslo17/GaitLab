# Unreleased — Codex development baseline (2026-10-28)

- Add repo-native Codex instructions, project-level model defaults, local/Cloud/macOS device workflow and research roadmap.
- Replace ZIP-first README bootstrap with a clone-first workflow.
- Correct eight CI analyzer lints identified by the first v0.4 GitHub Actions run.
- Make native Flutter runner generation non-destructive: generate into a temporary checkout and copy only missing native runners; preserve original app files and tests.
- Add optional Codex Cloud Linux Flutter installer and robust verification commands; explicitly separate Python, Dart, native build and physical-data validation status.

# GaitLab v0.4 changes

- Public dataset research and documented limitations in PUBLIC_DATASETS.md.
- Added public smartphone trial fetcher: verifies pinned Git blob SHA-1, does not bundle third-party data; script fails on missing/network changes.
- Added production-engine Dart CLI replay for running and sitting, used in optional GitHub Actions job. Does **not** misrepresent activity-only labels as step-count truth.
- Added independent contact scoring harness: one-to-one matches, precision/recall/F1/timing MAE, mandatory explicit alignment offset and optional force-plate onset extractor.
- 50–65 Hz now has a 'review' quality label rather than always 'unreliable'; <45 Hz remains unreliable. Unit test updated accordingly.
- Extended offline Python test suite; actual Dart replay, Android and iOS builds and on-belt accuracy remain pending execution.
