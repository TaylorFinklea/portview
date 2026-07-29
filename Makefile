# Portview local verification gates.
#
# No hosted CI yet — a GitHub Actions workflow is deliberately deferred
# (hosted macOS-26 runners are unreliable, and the package suite needs a real
# Keychain, loopback QUIC listeners and a hardware HEVC encoder). Run
# `make preflight` locally; `make bootstrap` installs it as a git pre-push hook.
#
# Fresh clone: run `make bootstrap` first. The .xcodeproj bundles are generated
# from project.yml by xcodegen and are NOT tracked (see .gitignore), so the
# xcodebuild legs below cannot run until they exist.

.PHONY: preflight bootstrap generate check-tools test-package build-host test-host test-ios release

# Developer-ID release pipeline (host). Requires a "Developer ID Application" certificate and a
# stored notarytool profile:
#   xcrun notarytool store-credentials $(NOTARY_PROFILE) \
#       --apple-id <apple-id> --team-id K7CBQW6MPG --password <app-specific-password>
NOTARY_PROFILE ?= portview
RELEASE_DIR    := build/release
ARCHIVE        := $(RELEASE_DIR)/PortviewHost.xcarchive
EXPORTED       := $(RELEASE_DIR)/export/PortviewHost.app
ZIP            := $(RELEASE_DIR)/PortviewHost.zip

HOST_PROJECT   := apps/PortviewHost/PortviewHost.xcodeproj
CLIENT_PROJECT := apps/PortviewClient/PortviewClient.xcodeproj
HOST_PBXPROJ   := $(HOST_PROJECT)/project.pbxproj
CLIENT_PBXPROJ := $(CLIENT_PROJECT)/project.pbxproj

preflight: test-package build-host test-host test-ios

# One-time setup for a fresh clone: verify prerequisites, generate both Xcode
# projects, and arm the pre-push gate.
bootstrap: generate
	@git config core.hooksPath scripts
	@echo "bootstrap: projects generated; pre-push gate armed (core.hooksPath=scripts)."
	@echo "bootstrap: next run 'make preflight'."

check-tools:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "error: xcodegen not found — both apps' .xcodeproj are generated from project.yml."; \
		echo "       install it with:  brew install xcodegen"; \
		exit 1; \
	}

generate: $(HOST_PBXPROJ) $(CLIENT_PBXPROJ)

# XcodeGen enumerates the Sources/Tests trees, so the generated project depends on WHICH FILES
# EXIST there, not just on project.yml — a new file must trigger a regenerate or the xcodebuild
# legs below silently compile a project that omits it.
HOST_INPUTS   := $(shell find apps/PortviewHost/Sources apps/PortviewHost/Tests -type f 2>/dev/null)
CLIENT_INPUTS := $(shell find apps/PortviewClient/Sources apps/PortviewClient/Tests -type f 2>/dev/null)

$(HOST_PBXPROJ): apps/PortviewHost/project.yml apps/Portview.xcconfig $(HOST_INPUTS) | check-tools
	cd apps/PortviewHost && xcodegen generate

$(CLIENT_PBXPROJ): apps/PortviewClient/project.yml apps/Portview.xcconfig $(CLIENT_INPUTS) | check-tools
	cd apps/PortviewClient && xcodegen generate

# --no-parallel on purpose: PipelineLatencyTests asserts a wall-clock bound and flakes under
# parallel load (bead portview-yur). A release gate has to be deterministic before it is fast.
test-package:
	swift test --package-path . --no-parallel

build-host: $(HOST_PBXPROJ)
	xcodebuild build -project $(HOST_PROJECT) -scheme PortviewHost -destination 'platform=macOS'

# Host-app unit tests (PortviewHostTests). A logic-test bundle with no TEST_HOST — the app is never
# launched — so this touches no keychain, LAContext, pasteboard, IOPM, CGEvent or SCStream.
test-host: $(HOST_PBXPROJ)
	xcodebuild test -project $(HOST_PROJECT) -scheme PortviewHost -destination 'platform=macOS'

test-ios: $(CLIENT_PBXPROJ)
	xcodebuild test -project $(CLIENT_PROJECT) -scheme PortviewClient -destination 'platform=iOS Simulator,name=iPhone 17'

# Archive → export (Developer ID) → notarize → staple → verify. Produces a stapled .app and a
# distributable zip under $(RELEASE_DIR).
#
# The zip is only a transport for notarytool; the STAPLE goes on the .app, so the zip is rebuilt
# from the stapled bundle afterwards. Shipping the pre-staple zip would hand users a bundle that
# needs a network round-trip to Apple on first launch — and fails Gatekeeper offline.
release: $(HOST_PBXPROJ)
	@command -v xcrun >/dev/null 2>&1 || { echo "error: xcrun not found"; exit 1; }
	@xcrun notarytool history --keychain-profile $(NOTARY_PROFILE) >/dev/null 2>&1 || { \
		echo "error: no notarytool profile '$(NOTARY_PROFILE)'. Create one with:"; \
		echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"; \
		echo "      --apple-id <apple-id> --team-id K7CBQW6MPG --password <app-specific-password>"; \
		exit 1; \
	}
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	xcodebuild archive -project $(HOST_PROJECT) -scheme PortviewHost -configuration Release \
		-destination 'generic/platform=macOS' -archivePath $(ARCHIVE) -allowProvisioningUpdates
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist apps/PortviewHost/ExportOptions.plist \
		-exportPath $(RELEASE_DIR)/export -allowProvisioningUpdates
	ditto -c -k --keepParent $(EXPORTED) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(EXPORTED)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(EXPORTED) $(ZIP)
	@echo "--- verification ---"
	xcrun stapler validate $(EXPORTED)
	spctl -a -vvv $(EXPORTED)
	@echo "release: $(ZIP)"
