DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# WHERE A HOST ACTUALLY READS FROM.
#
# This was `.../Documents/DevPlugins` and had been writing where nothing reads
# since `VaultMigration.swift:154` moved the directory under `Cache/`. A
# sideload appeared to succeed, the host loaded its INSTALLED copy of the
# plugin instead, and the difference is invisible unless you check the process's
# mappings with `vmmap` — which is how M9 spent four milestones believing it had
# verified a load it had not.
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins
# The Dev Host is a SEPARATE app with its own bundle identifier, so it reads a
# different directory. `sideload` alone can never reach it — that is why the
# plugin went three milestones without once being loaded by a host.
HOST_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.devhost/Documents/DevPlugins
DEV_HOST := $(HOME)/Home/Projects/Ainkrad/Ainkrad/build/Build/Products/Debug/AinkradDevHost.app
# The DEBUG Ainkrad, which is the only host that reads DevPlugins at all:
# `PluginTrust.scansDevPluginsDirectory` is Debug-only, so a release
# /Applications/Ainkrad.app will never load a sideloaded build no matter what
# is copied where.
#
# A repo-relative path, NOT a DerivedData one. It briefly was the latter,
# complete with Xcode's hash in it, and the app had already vanished from there
# by the next build — which is the whole argument for the sibling repo's
# `build` target passing `-derivedDataPath build` (fixed 2026-08-20) so that
# there is one predictable place to point at.
AINKRAD := $(abspath $(CURDIR)/../Ainkrad)
DEBUG_APP := $(AINKRAD)/build/Build/Products/Debug/Ainkrad.app

# EVERY target here is a verb, and none of them produces a file of its own
# name. Without this, make compares the target against a like-named PATH — and
# on a case-insensitive filesystem `editor` matches the `Editor/` directory and
# `build` matches `build/`, so the recipe is skipped and the tool reports
# success having done nothing. `make editor` silently stopped rebuilding the
# JavaScript bundle this way; `build` escaped only because its `generate`
# prerequisite can never be up to date.
.PHONY: editor generate build sideload run devhost test parity release

# The CM6 bundle. `dist/` is COMMITTED, so a clean checkout — and the release
# script, and CI — build the plugin with no node installed. Only someone
# changing the editor's JavaScript needs this target.
editor: ; cd Editor && npm install && npm run build

generate: ; xcodegen generate
build: lint generate ; xcodebuild -scheme LorePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
# `ditto`, not `rm -rf` + `cp -R`: copying a bundle INTO a directory that
# already contains one of the same name nests it
# (LorePlugin.bundle/LorePlugin.bundle) and leaves the old binary in place,
# which looks like a sideload that did nothing.
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	ditto build/Build/Products/Debug/LorePlugin.bundle "$(DEV_PLUGINS)/LorePlugin.bundle"
	@shasum -a 1 "$(DEV_PLUGINS)/LorePlugin.bundle/Contents/MacOS/LorePlugin" \
	             build/Build/Products/Debug/LorePlugin.bundle/Contents/MacOS/LorePlugin

# Sideload and launch the DEBUG Ainkrad, then PROVE the bundle is mapped into
# the running process. A copy is not a load.
#
# The witness is `vmmap`, NOT `lsof`. `lsof` lists open FILE DESCRIPTORS, and a
# loaded Mach-O is mapped, not held open — dyld closes the descriptor once the
# mapping exists. So `lsof` reports a loaded plugin only during the brief window
# the file is still open, which is why it gave false negatives during M9 and,
# worse, occasional false positives that were then reported as verification.
# `vmmap` lists the mappings themselves, which is the thing being asserted.
run: sideload
	@pid=$$(scripts/debug-host-pid.sh "$(DEBUG_APP)"); [ -z "$$pid" ] || kill $$pid; sleep 2
	open -n "$(DEBUG_APP)"
	@echo "waiting for the plugin to be mapped…"
	@for i in $$(seq 1 30); do \
		sleep 2; \
		pid=$$(scripts/debug-host-pid.sh "$(DEBUG_APP)"); \
		if [ -n "$$pid" ] && vmmap $$pid 2>/dev/null \
		     | grep -q "DevPlugins/LorePlugin.bundle/Contents/MacOS"; then \
			echo "LOADED pid=$$pid"; exit 0; \
		fi; \
	done; \
	echo "NOT LOADED — the host is running the installed copy, not this build"; exit 1
# Load Lore in the Dev Host. `open -n` so this never disturbs a Dev Host
# instance already running someone else's plugin, and the bundle path is passed
# explicitly because the Dev Host scans no directories — it loads exactly the
# one bundle named by --bundle, eagerly, at window appearance.
devhost: build
	mkdir -p "$(HOST_PLUGINS)"
	rm -rf "$(HOST_PLUGINS)/LorePlugin.bundle"
	cp -R build/Build/Products/Debug/LorePlugin.bundle "$(HOST_PLUGINS)/LorePlugin.bundle"
	open -n "$(DEV_HOST)" --args --bundle "$(HOST_PLUGINS)/LorePlugin.bundle"

test: lint generate ; xcodebuild -scheme LorePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
# Tier A parity shots (Epic 5B, 5B.0): both editor surfaces and the SwiftUI
# screens, under all seven host palettes, rendered off-screen — no host, so it
# can never touch the daily one. `LORE_PARITY_DIR` is required; xcodebuild only
# forwards `TEST_RUNNER_`-prefixed variables to the test process.
#   LORE_PARITY_DIR=~/Home/Projects/Ainkrad/Designs/parity/AinkradLore/before make parity
parity: generate
	@test -n "$(LORE_PARITY_DIR)" || { echo "parity: set LORE_PARITY_DIR=<output dir>"; exit 2; }
	TEST_RUNNER_LORE_PARITY_DIR="$(abspath $(LORE_PARITY_DIR))" xcodebuild -scheme LorePlugin \
		-configuration Debug -derivedDataPath build -destination 'platform=macOS' test \
		-only-testing:LoreFeatureTests/CM6ParityShotTests \
		-only-testing:LoreFeatureTests/LoreScreenSnapshotTests
release: ; ./scripts/release.sh $(V)

include scripts/guardrails.mk
