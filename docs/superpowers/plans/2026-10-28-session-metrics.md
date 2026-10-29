# Session Metrics Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans. Keep work in the current checkout as required by AGENTS.md.

**Goal:** Implement the four user-approved metric groups and install the tested app on the connected phone.

**Architecture:** Signal processing and session metrics are pure Dart in lib/gait_engine.dart. Acquisition and charts remain in lib/main.dart. Recording and additive export remain in lib/session_recorder.dart. Preserve original accelerometer, gyro, steps and quality schemas.

**Tech Stack:** Existing Flutter dependencies, CustomPainter charts, Dart tests. No new application dependency.

**Spec:** docs/METRIC_ASSESSMENT.md and the user's explicit request to implement and install all proposed features.

## Constraints

- Cadence and CV remain experimental candidate-event metrics. No medical, asymmetry, contact-time or impact-force claims.
- Target is optional, user-defined, adjustable before recording; default range 160–180 spm is editable and is not a recommendation.
- Time charts use native elapsed sensor time, preserve gaps, show a trailing 120-second view and keep full session exports.
- No detector parameter tuning. New metadata and metric export are additive.
- Available-time totals use elapsed seconds, never sample-count percentages. Gaps over 70 ms receive no quality credit. Target percentage denominator includes only usable-quality cadence time.
- Foreground-only lifecycle and existing raw recording safeguards remain.

## Review focus

- No samples / insufficient events: absent metrics stay null, UI displays an em dash.
- Rate changes, missing samples and stopped feed: no stale cadence time credit or drawn lines across gaps.
- Target edits / session reset: no mixing target settings across sessions.
- Background or startup failure: clean stop and export handling remains intact.
- Narrow screens and long recordings: charts remain bounded on screen, text does not overflow, exports retain all points.

## Tasks

- [x] Pure Dart metrics: optional CadenceTarget, time-weighted session summary, timestamped 1-second MetricPoint trends, grade-duration totals, experimental CV. Tests first for unavailable values, gap accounting, target denominators, reset and nonmonotonic inputs.
- [x] Recorder: add metrics.csv, target/metric-definition metadata, and metric summary without changing six existing file schemas. Verify actual output with temporary-directory tests.
- [x] UI integration: optional target controls, cadence graph and quality strip, duration/coverage summary, expandable CV/RMS/regularity charts with definitions and limitations. Widget tests for target control and empty states.
- [x] Quality gate: Flutter analysis, full Flutter tests, Python QA tests, relevant device build, independent code review and fixes.
- [x] Install and launch on the connected phone. Record exact device, build, install and hardware evidence; distinguish installation from running accuracy.

Ruling: prior user approval covers the metric scope and direct phone installation. Continue without another permission gate. No commit, push or release is required.

Verification: 34 Flutter tests and 40 Python tests pass; Flutter analysis is clean. Android arm64 debug APK built and installed on SM S9210. Foreground capture and seven-file integrity checked on hardware; no running accuracy claim. A chart empty-state text found during device inspection was corrected and rebuilt.
