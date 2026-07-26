# Portview local verification gates.
#
# No hosted CI yet — a GitHub Actions workflow is deliberately deferred
# (hosted macOS-26 runners are unreliable). Run `make preflight` locally;
# scripts/pre-push installs it as a git pre-push hook (see apps/README.md).

.PHONY: preflight test-package build-host test-host test-ios

preflight: test-package build-host test-host test-ios

test-package:
	swift test --package-path .

build-host:
	xcodebuild build -project apps/PortviewHost/PortviewHost.xcodeproj -scheme PortviewHost -destination 'platform=macOS'

# Host-app unit tests (PortviewHostTests). A logic-test bundle with no TEST_HOST — the app is never
# launched — so this touches no keychain, LAContext, pasteboard, IOPM, CGEvent or SCStream.
test-host:
	xcodebuild test -project apps/PortviewHost/PortviewHost.xcodeproj -scheme PortviewHost -destination 'platform=macOS'

test-ios:
	xcodebuild test -project apps/PortviewClient/PortviewClient.xcodeproj -scheme PortviewClient -destination 'platform=iOS Simulator,name=iPhone 17'
