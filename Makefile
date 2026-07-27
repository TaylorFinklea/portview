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

.PHONY: preflight bootstrap generate check-tools test-package build-host test-host test-ios

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

# Regenerate only when the project definition or the shared xcconfig changes.
$(HOST_PBXPROJ): apps/PortviewHost/project.yml apps/Portview.xcconfig | check-tools
	cd apps/PortviewHost && xcodegen generate

$(CLIENT_PBXPROJ): apps/PortviewClient/project.yml apps/Portview.xcconfig | check-tools
	cd apps/PortviewClient && xcodegen generate

test-package:
	swift test --package-path .

build-host: $(HOST_PBXPROJ)
	xcodebuild build -project $(HOST_PROJECT) -scheme PortviewHost -destination 'platform=macOS'

# Host-app unit tests (PortviewHostTests). A logic-test bundle with no TEST_HOST — the app is never
# launched — so this touches no keychain, LAContext, pasteboard, IOPM, CGEvent or SCStream.
test-host: $(HOST_PBXPROJ)
	xcodebuild test -project $(HOST_PROJECT) -scheme PortviewHost -destination 'platform=macOS'

test-ios: $(CLIENT_PBXPROJ)
	xcodebuild test -project $(CLIENT_PROJECT) -scheme PortviewClient -destination 'platform=iOS Simulator,name=iPhone 17'
