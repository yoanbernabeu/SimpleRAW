DEVELOPER_DIR := $(shell xcode-select -p)

# With the Command Line Tools alone (no Xcode), SwiftPM does not find Swift Testing on
# its own: it has to be told where the framework is installed.
ifeq ($(DEVELOPER_DIR),/Library/Developer/CommandLineTools)
TESTING_FRAMEWORKS := $(DEVELOPER_DIR)/Library/Developer/Frameworks
TESTING_LIBS := $(DEVELOPER_DIR)/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F -Xswiftc $(TESTING_FRAMEWORKS) \
	-Xlinker -F -Xlinker $(TESTING_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TESTING_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TESTING_LIBS)
endif

# Everything that renders runs under a memory limit: a mistake in a Core Image graph can ask
# for hundreds of gigabytes, and macOS reboots rather than kill the process. The limits are
# far above what the suite and the app need, and far below what the machine has.
GUARD := .build/memory-guard
TEST_MEMORY_LIMIT_GB := 8
RUN_MEMORY_LIMIT_GB := 12

.PHONY: build release test test-clone test-s3 bench gestures app s3-up s3-down run clean

$(GUARD): scripts/memory-guard.swift
	@mkdir -p .build
	swiftc -O scripts/memory-guard.swift -o $(GUARD)

build:
	swift build

release:
	swift build -c release

# Tests that need a real RAW file are skipped without one: say so, rather than pass quietly.
test: $(GUARD)
	@ls Samples/*.[dD][nN][gG] >/dev/null 2>&1 || echo "warning: no DNG in Samples/ — RAW end-to-end tests will be skipped (see CLAUDE.md for the reference sample)"
	$(GUARD) $(TEST_MEMORY_LIMIT_GB) swift test $(TEST_FLAGS)

# The suite as a fresh clone runs it, without the git-ignored samples.
test-clone: $(GUARD)
	SIMPLERAW_NO_SAMPLES=1 $(GUARD) $(TEST_MEMORY_LIMIT_GB) swift test $(TEST_FLAGS)

# Fluidity is a requirement: replays every continuous gesture in release and fails when one
# goes over the 16 ms frame budget. Needs a DNG in Samples/ and a quiet machine.
bench: $(GUARD)
	SIMPLERAW_BENCH=1 $(GUARD) $(TEST_MEMORY_LIMIT_GB) swift test -c release $(TEST_FLAGS) --filter "FluidityBenchmarks|EngineBenchmarks|CatalogBenchmarks" 2>&1 | grep -E "^BENCH|recorded an issue|Test run with|error:"

# The app as it is distributed: a real bundle, sandboxed, ad-hoc signed. `make app OPEN=1`
# starts it. Developer ID and notarisation wait for the Apple account.
app:
	scripts/make-app.sh $(if $(OPEN),--open)

# Presses the app's own buttons with real mouse events: the only check that a gesture
# reaches the code every other test calls directly. Needs a DNG in Samples/.
gestures: $(GUARD)
	scripts/exercise-gestures.sh "$(GESTURE)"

# A throwaway S3 server (MinIO, in Docker) for the backup's integration tests. Nothing is
# kept: no volume, and the container is removed when it stops.
# The image is pinned to a release and to its digest, not to `latest`: the tests run against
# the same server tomorrow as today, and Docker checks that it is that one.
# Test credentials, never reuse: they open a server that lives for one test run, on 127.0.0.1.
S3_IMAGE := quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e
S3_PORT := 19000
S3_ENV := SIMPLERAW_S3_ENDPOINT=http://127.0.0.1:$(S3_PORT) SIMPLERAW_S3_ACCESS_KEY=simpleraw SIMPLERAW_S3_SECRET_KEY=simpleraw-secret

s3-up:
	@docker rm -f simpleraw-minio >/dev/null 2>&1 || true
	docker run -d --rm --name simpleraw-minio -p 127.0.0.1:$(S3_PORT):9000 \
		-e MINIO_ROOT_USER=simpleraw -e MINIO_ROOT_PASSWORD=simpleraw-secret \
		$(S3_IMAGE) server /data
	@until curl -sf http://127.0.0.1:$(S3_PORT)/minio/health/ready >/dev/null; do sleep 0.5; done

s3-down:
	@docker rm -f simpleraw-minio >/dev/null 2>&1 || true

# Runs the whole suite with the S3 integration tests switched on.
test-s3: $(GUARD) s3-up
	$(S3_ENV) $(GUARD) $(TEST_MEMORY_LIMIT_GB) swift test $(TEST_FLAGS); status=$$?; $(MAKE) s3-down; exit $$status

# make run [FILE=Samples/photo.dng] [LOOK=look.json]
# Optimized on purpose: lookup tables are rebuilt on every frame of a slider drag, which
# takes 0.2 ms in release and over 100 ms in debug.
run: $(GUARD)
	swift build -c release --product SimpleRAWApp
	$(GUARD) $(RUN_MEMORY_LIMIT_GB) .build/release/SimpleRAWApp $(if $(FILE),-file $(abspath $(FILE))) $(if $(LOOK),-look $(abspath $(LOOK)))

clean:
	swift package clean
