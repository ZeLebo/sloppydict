VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
RELEASE_APP := build/release/SloppyDict.app
ARCHIVE := SloppyDict-v$(VERSION)-macos-arm64.zip

.PHONY: build package test test-layout test-native check hooks

build: build/AppIcon.icns
	swift build -j 2 -c release --product SloppyDict
	mkdir -p build/SloppyDict.app/Contents/MacOS
	cp .build/release/SloppyDict build/SloppyDict.app/Contents/MacOS/
	cp Resources/Info.plist build/SloppyDict.app/Contents/
	mkdir -p build/SloppyDict.app/Contents/Resources
	cp build/AppIcon.icns build/SloppyDict.app/Contents/Resources/
	codesign --force --sign - build/SloppyDict.app

build/AppIcon.icns: Resources/AppIcon.png scripts/build-icon.py
	python3 scripts/build-icon.py

# Prepare a separate, ad hoc signed download without touching the development app.
package: check build/AppIcon.icns
	swift build -j 2 -c release --arch arm64 --product SloppyDict \
		-Xswiftc -debug-prefix-map -Xswiftc "$(HOME)=/build" \
		-Xswiftc -file-prefix-map -Xswiftc "$(HOME)=/build" \
		-Xswiftc -Xfrontend -Xswiftc -no-serialize-debugging-options \
		-Xcc "-ffile-prefix-map=$(HOME)=/build" -Xcc "-fdebug-prefix-map=$(HOME)=/build"
	mkdir -p "$(RELEASE_APP)/Contents/MacOS" "$(RELEASE_APP)/Contents/Resources/Licenses"
	cp "$$(swift build -c release --arch arm64 --show-bin-path)/SloppyDict" "$(RELEASE_APP)/Contents/MacOS/"
	cp Resources/Info.plist "$(RELEASE_APP)/Contents/"
	cp build/AppIcon.icns "$(RELEASE_APP)/Contents/Resources/"
	cp THIRD_PARTY_NOTICES.md "$(RELEASE_APP)/Contents/Resources/"
	cp .build/checkouts/FluidAudio/LICENSE "$(RELEASE_APP)/Contents/Resources/Licenses/FluidAudio-LICENSE.txt"
	cp .build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md "$(RELEASE_APP)/Contents/Resources/Licenses/"
	strip -S "$(RELEASE_APP)/Contents/MacOS/SloppyDict"
	codesign --force --sign - "$(RELEASE_APP)"
	codesign --verify --deep --strict "$(RELEASE_APP)"
	ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$(RELEASE_APP)" "build/$(ARCHIVE)"
	cd build && shasum -a 256 "$(ARCHIVE)" > "$(ARCHIVE).sha256"

test:
	mkdir -p .build
	swiftc -parse-as-library Sources/DictationCore/*.swift Tests/DictationCoreTests/RecordingStateTests.swift -o .build/core-checks
	.build/core-checks
	swiftc -parse-as-library Sources/SloppyDict/RegisteredHotkeyEvents.swift Tests/HotkeyEventChecks.swift -o .build/hotkey-checks
	.build/hotkey-checks
	swiftc -parse-as-library Sources/SloppyDict/LiveTranscription.swift Tests/LiveTranscriptionChecks.swift -o .build/live-transcription-checks
	.build/live-transcription-checks
	python3 -m unittest discover -s scripts/tests

test-layout:
	mkdir -p .build/hud-layout
	swiftc -parse-as-library -whole-module-optimization -emit-object -emit-module -module-name DictationCore -emit-module-path .build/hud-layout/DictationCore.swiftmodule Sources/DictationCore/*.swift -o .build/hud-layout/DictationCore.o
	swiftc -parse-as-library -I .build/hud-layout .build/hud-layout/DictationCore.o Sources/SloppyDict/DictationHUD.swift Sources/SloppyDict/HotkeyMonitor.swift Sources/SloppyDict/RegisteredHotkeyEvents.swift Sources/SloppyDict/DictationError.swift Tests/HUDLayoutChecks.swift -o .build/hud-layout-checks
	.build/hud-layout-checks

test-native:
	swiftc -parse-as-library Sources/SloppyDict/DictationError.swift Sources/SloppyDict/TextInsertion.swift Tests/DeliveryChecks.swift -o .build/delivery-checks
	.build/delivery-checks

check:
	python3 scripts/check-source.py

hooks:
	git config --local core.hooksPath .githooks
