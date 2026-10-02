# VoiceToText — CLI build entry points. See .omc/plans/ralplan-mac-voice-to-text.md (Step 1).
SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c

PROJECT   := VoiceToText.xcodeproj
SCHEME    := VoiceToText
BUNDLE_ID := com.keunbae.VoiceToText
LOG_DIR   := build/logs
APP       := $(HOME)/Applications/VoiceToText.app
FIXTURE   := Core/Tests/VoiceToTextIntegrationTests/Fixtures/hello-10s.wav

# SHA-1 of the signing identity chosen by `make bootstrap` (override on the command line if needed).
VTT_SIGN_IDENTITY ?= $(shell cat .signing-identity 2>/dev/null)

# Zero-tests guard (N2): Swift Testing prints "Test run with N tests ...".
TESTS_RAN := Test run with [1-9][0-9]* test

.PHONY: bootstrap gen build test itest fixtures run dmg reset-tcc latency check

bootstrap:
	scripts/bootstrap.sh

gen:
	xcodegen generate

build: gen
	@test -n "$(VTT_SIGN_IDENTITY)" || { echo "!! No signing identity; run make bootstrap" >&2; exit 1; }
	@mkdir -p $(LOG_DIR)
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath build \
		VTT_SIGN_IDENTITY=$(VTT_SIGN_IDENTITY) build 2>&1 | tee $(LOG_DIR)/build.log
	@! grep 'warning:' $(LOG_DIR)/build.log | grep -v 'appintentsmetadataprocessor.*No AppIntents.framework dependency found' \
		|| { echo "!! build produced warnings" >&2; exit 1; }

test:
	@mkdir -p $(LOG_DIR)
	set -o pipefail; swift test --package-path Core --skip VoiceToTextIntegrationTests $(TEST_ARGS) 2>&1 | tee $(LOG_DIR)/test.log
	@grep -Eq '$(TESTS_RAN)' $(LOG_DIR)/test.log || { echo "!! zero tests ran" >&2; exit 1; }

itest: fixtures
	@mkdir -p $(LOG_DIR)
	set -o pipefail; swift test --package-path Core --filter VoiceToTextIntegrationTests $(TEST_ARGS) 2>&1 | tee $(LOG_DIR)/itest.log
	@grep -Eq '$(TESTS_RAN)' $(LOG_DIR)/itest.log || { echo "!! zero integration tests ran" >&2; exit 1; }
	@grep -q 'stt_ms p50=' $(LOG_DIR)/itest.log || { echo "!! no 'stt_ms p50=' line in integration output" >&2; exit 1; }

fixtures:
	scripts/make-fixtures.sh

run: build
	scripts/install.sh

# Shareable (not notarized) disk image: build/dmg/VoiceToText.dmg
dmg:
	VTT_SIGN_IDENTITY=$(VTT_SIGN_IDENTITY) scripts/make-dmg.sh

reset-tcc:
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset ListenEvent $(BUNDLE_ID)
	-tccutil reset Microphone $(BUNDLE_ID)
	-tccutil reset SpeechRecognition $(BUNDLE_ID)

latency:
	scripts/latency-report.sh

# Plan §7 automated greps; fails on the first violation.
check:
	@echo "AC6: no audio persistence"; \
	! grep -rn "AVAudioFile\|temporaryDirectory\|FileManager" Core/Sources App/Audio
	@echo "AC6a: Speech only in Transcription/Apple and PermissionsManager"; \
	! grep -rln "import Speech" Core/Sources App | grep -v "Transcription/Apple/" | grep -v "App/System/PermissionsManager.swift"
	@echo "AC14: no network code"; \
	! grep -rnE "URLSession|URLRequest|NWConnection|import Network|CFNetwork" Core/Sources App
	@echo "R9: no maskAlternate"; \
	! grep -rn "maskAlternate" App/System
	@echo "AC14: PassthroughCleaner() wired exactly once"; \
	test "$$(grep -c "PassthroughCleaner()" App/AppEnvironment.swift)" -eq 1
	@echo "No TODO/FIXME/skips"; \
	! grep -rn --exclude-dir=.build "TODO\|FIXME\|\.skip\|XCTSkip\|disabled:" Core App
	@echo "==> make check: all greps passed"
