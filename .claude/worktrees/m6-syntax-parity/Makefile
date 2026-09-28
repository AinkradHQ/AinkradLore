DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Documents/DevPlugins
# The Dev Host is a SEPARATE app with its own bundle identifier, so it reads a
# different directory. `sideload` alone can never reach it — that is why the
# plugin went three milestones without once being loaded by a host.
HOST_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.devhost/Documents/DevPlugins
DEV_HOST := $(HOME)/Home/Projects/Ainkrad/Ainkrad/build/Build/Products/Debug/AinkradDevHost.app

generate: ; xcodegen generate
build: generate ; xcodebuild -scheme LorePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/LorePlugin.bundle"
	cp -R build/Build/Products/Debug/LorePlugin.bundle "$(DEV_PLUGINS)/LorePlugin.bundle"
# Load Lore in the Dev Host. `open -n` so this never disturbs a Dev Host
# instance already running someone else's plugin, and the bundle path is passed
# explicitly because the Dev Host scans no directories — it loads exactly the
# one bundle named by --bundle, eagerly, at window appearance.
devhost: build
	mkdir -p "$(HOST_PLUGINS)"
	rm -rf "$(HOST_PLUGINS)/LorePlugin.bundle"
	cp -R build/Build/Products/Debug/LorePlugin.bundle "$(HOST_PLUGINS)/LorePlugin.bundle"
	open -n "$(DEV_HOST)" --args --bundle "$(HOST_PLUGINS)/LorePlugin.bundle"

test: generate ; xcodebuild -scheme LorePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
release: ; ./scripts/release.sh $(V)
