# `make check` runs what CI runs, plus the Swift lint when Xcode is present.
SWIFT_SOURCES = BiomimeticRadar BiomimeticRadarTests cardiomagprobe/CardioMagProbe cardiomagprobe/CardioMagProbeTests Package.swift

.PHONY: check lint swift-lint test swift-test cardiomag-test format

check: lint swift-lint test

lint:
	uv run ruff check .

# swift-format ships with Xcode; skipped where there is none (CI runs on Linux).
swift-lint:
	@if command -v xcrun >/dev/null 2>&1; then xcrun swift-format lint --strict -r $(SWIFT_SOURCES); \
	else echo "swift-lint skipped: no Xcode"; fi

# The gate. A scratch store, never streams/: that is the only copy of the phone's recordings.
test:
	FIELDLAB_STREAMS=$$(mktemp -d) uv run python dev_check.py

# XCTests over the platform-independent core (Package.swift). Slow: a few minutes.
swift-test:
	swift test

cardiomag-test:
	cd cardiomagprobe/analysis && uv run python -m pytest -q test_analysis.py

format:
	uv run ruff check --fix .
	xcrun swift-format format -i -r $(SWIFT_SOURCES)
