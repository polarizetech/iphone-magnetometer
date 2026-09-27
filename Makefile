# `make check` runs what CI runs, plus the Swift lint when Xcode is present.
# The protocol checker: CI passes SCAFFOLD="python3 .scaffold/bin/scaffold"; locally it falls back to a
# sibling checkout of polarizetech/scientific-research-scaffold.
SCAFFOLD ?= $(shell command -v scaffold 2>/dev/null || echo python3 ../scientific-research-scaffold/bin/scaffold)
SWIFT_SOURCES = BiomimeticRadar BiomimeticRadarTests cardiomagprobe/CardioMagProbe cardiomagprobe/CardioMagProbeTests Package.swift

.PHONY: check scaffold-check lint swift-lint test swift-test format

check: scaffold-check lint swift-lint test

scaffold-check:
	$(SCAFFOLD) check .

lint:
	uv run ruff check .

# swift-format ships with Xcode; skipped where there is none (CI runs on Linux).
swift-lint:
	@if command -v xcrun >/dev/null 2>&1; then xcrun swift-format lint --strict -r $(SWIFT_SOURCES); \
	else echo "swift-lint skipped: no Xcode"; fi

# The gate. A scratch store, never streams/: that is the only copy of the phone's recordings.
test:
	FIELDLAB_STREAMS=$$(mktemp -d) uv run python dev_check.py

# 70 XCTests over the platform-independent core (Package.swift). Slow: about four minutes.
swift-test:
	swift test

format:
	uv run ruff check --fix .
	xcrun swift-format format -i -r $(SWIFT_SOURCES)
