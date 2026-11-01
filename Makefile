VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
RELEASE_APP := build/release/SloppyDict.app
ARCHIVE := SloppyDict-v$(VERSION)-macos-arm64.zip

.PHONY: build package test test-native check hooks

build:
	swift build -j 2 -c release --product SloppyDict
	mkdir -p build/SloppyDict.app/Contents/MacOS
	cp .build/release/SloppyDict build/SloppyDict.app/Contents/MacOS/
	cp Resources/Info.plist build/SloppyDict.app/Contents/
	codesign --force --sign - build/SloppyDict.app

# Prepare a separate, ad hoc signed download without touching the development app.
package: check
	swift build -j 2 -c release --arch arm64 --product SloppyDict \
		-Xswiftc -debug-prefix-map -Xswiftc "$(HOME)=/build" \
		-Xswiftc -file-prefix-map -Xswiftc "$(HOME)=/build" \
		-Xswiftc -Xfrontend -Xswiftc -no-serialize-debugging-options \
		-Xcc "-ffile-prefix-map=$(HOME)=/build" -Xcc "-fdebug-prefix-map=$(HOME)=/build"
	mkdir -p "$(RELEASE_APP)/Contents/MacOS" "$(RELEASE_APP)/Contents/Resources/Licenses"
	cp "$$(swift build -c release --arch arm64 --show-bin-path)/SloppyDict" "$(RELEASE_APP)/Contents/MacOS/"
	cp Resources/Info.plist "$(RELEASE_APP)/Contents/"
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
	python3 -m unittest discover -s scripts/tests

test-native:
	swiftc -parse-as-library Sources/SloppyDict/DictationError.swift Sources/SloppyDict/TextInsertion.swift Tests/DeliveryChecks.swift -o .build/delivery-checks
	.build/delivery-checks

check:
	python3 scripts/check-source.py

hooks:
	git config --local core.hooksPath .githooks
