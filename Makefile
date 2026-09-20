PROJECT := MicMyDay.xcodeproj
SCHEME := MicMyDay
BUILD_DERIVED_DATA := .build/xcode
RELEASE_DERIVED_DATA := .build/release
TEST_DERIVED_DATA := .build/tests
VENDOR_DIR := Vendor
WHISPER_RELEASE := b4938
LLAMA_RELEASE := b10908

.PHONY: generate build build-release test run run-release clean vendor archive release

$(VENDOR_DIR)/whisper.xcframework:
	mkdir -p $(VENDOR_DIR)
	curl -fsSL -o $(VENDOR_DIR)/whisper-xcframework.zip \
		https://github.com/ggml-org/whisper.cpp/releases/download/$(WHISPER_RELEASE)/whisper-$(WHISPER_RELEASE)-xcframework.zip
	unzip -q -o $(VENDOR_DIR)/whisper-xcframework.zip -d $(VENDOR_DIR)
	mv $(VENDOR_DIR)/build-apple/whisper.xcframework $(VENDOR_DIR)/whisper.xcframework
	rm -rf $(VENDOR_DIR)/build-apple $(VENDOR_DIR)/whisper-xcframework.zip

$(VENDOR_DIR)/llama.xcframework:
	mkdir -p $(VENDOR_DIR)
	curl -fsSL -o $(VENDOR_DIR)/llama-xcframework.zip \
		https://github.com/ggml-org/llama.cpp/releases/download/$(LLAMA_RELEASE)/llama-$(LLAMA_RELEASE)-xcframework.zip
	unzip -q -o $(VENDOR_DIR)/llama-xcframework.zip -d $(VENDOR_DIR)
	mv $(VENDOR_DIR)/build-apple/llama.xcframework $(VENDOR_DIR)/llama.xcframework
	rm -rf $(VENDOR_DIR)/build-apple $(VENDOR_DIR)/llama-xcframework.zip

vendor: $(VENDOR_DIR)/whisper.xcframework $(VENDOR_DIR)/llama.xcframework

generate: vendor
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DERIVED_DATA) build

# The shipping configuration. Worth running rather than the Debug build when
# checking what users actually see: the Settings sidebar hides its States pane
# outside DEBUG, so Debug shows one pane more than anybody else gets.
build-release: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(RELEASE_DERIVED_DATA) build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(TEST_DERIVED_DATA) test

# Creates a local candidate archive only; does not export, validate remotely,
# upload, or publish.
archive: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath .build/app-store-release \
		-archivePath .build/MicMyDay.xcarchive -allowProvisioningUpdates archive

run: build
	-pkill -x MicMyDay
	open "$(BUILD_DERIVED_DATA)/Build/Products/Debug/MicMyDay.app"

run-release: build-release
	-pkill -x MicMyDay
	open "$(RELEASE_DERIVED_DATA)/Build/Products/Release/MicMyDay.app"

# A build from source: licensed by definition, and it never updates itself.
# The source is GPL-3.0, so anyone may compile and run it; the paid download
# buys the prepared article rather than the right to run the code.
build-local: vendor
	LOCAL_BUILD=LOCAL_BUILD xcodegen generate
	LOCAL_BUILD=LOCAL_BUILD xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -derivedDataPath $(BUILD_DERIVED_DATA) build
	@echo
	@echo "Built from source. Licensing and automatic updates are compiled out."
	@echo "The app is at $(BUILD_DERIVED_DATA)/Build/Products/Release/MicMyDay.app"

# What the last release said it was. The same numbers the next one starts from.
version:
	@printf '%s (build %s)\n' \
		"$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MicMyDay/Resources/Info.plist)" \
		"$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' MicMyDay/Resources/Info.plist)"

# Builds, notarises, signs and adds a release to the appcast. Publishes
# nothing: it prints the commands that do.
#
# Both numbers are optional and read from Info.plist when left out: the build
# climbs by one, and the version stays as it is. Give VERSION for a release
# that is more than a rebuild.
#   make release                     the next build of this version
#   make release VERSION=1.1.0       a new version, next build number
#   make release VERSION=1.1.0 BUILD=42
release:
	Distribution/release.sh $(VERSION) $(BUILD)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD_DERIVED_DATA) clean
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(TEST_DERIVED_DATA) clean
