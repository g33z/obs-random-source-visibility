PLUGIN_NAME := obs-random-source-visibility
PLUGIN_VERSION := $(shell sed -n -E 's/^project[^V]*VERSION ([0-9.]+).*/\1/p' CMakeLists.txt)
PLUGIN_MAINTAINER ?= $(shell git config user.name 2>/dev/null) <$(shell git config user.email 2>/dev/null)>

BUILD_DIR := build
STAGE_DIR := $(BUILD_DIR)/stage
DIST_DIR := $(BUILD_DIR)/dist
DEPS_DIR := .deps

WIN_BUILD_DIR := $(BUILD_DIR)/windows
WIN_STAGE_DIR := $(WIN_BUILD_DIR)/stage

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

CMAKE_ARGS :=
ifdef libobs_DIR
CMAKE_ARGS += -Dlibobs_DIR=$(libobs_DIR)
endif

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
OBS_PLUGIN_DIR := $(HOME)/Library/Application Support/obs-studio/plugins
OBS_APP_BUNDLE ?= /Applications/OBS.app
OBS_VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(OBS_APP_BUNDLE)/Contents/Info.plist" 2>/dev/null)
OBS_SRC_DIR := $(DEPS_DIR)/obs-studio-$(OBS_VERSION)
CMAKE_ARGS += -DOBS_APP_BUNDLE=$(OBS_APP_BUNDLE)
else ifeq ($(UNAME_S),Linux)
OBS_PLUGIN_DIR := $(HOME)/.config/obs-studio/plugins
endif

.PHONY: deps configure build stage install package clean rebuild release hooks \
	deps-windows configure-windows build-windows stage-windows package-windows clean-windows \
	maintenance outdated audit

# Lets `make release x.y.z` pass "x.y.z" through to bin/release.sh instead of
# Make trying to build it as a goal. Only matched when it looks like a
# version, so a typo'd argument still fails loudly rather than becoming a no-op.
ifeq (release,$(firstword $(MAKECMDGOALS)))
RELEASE_ARG := $(word 2,$(MAKECMDGOALS))
ifeq ($(shell echo '$(RELEASE_ARG)' | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$$' && echo yes),yes)
$(eval $(RELEASE_ARG):;@:)
endif
endif

.DEFAULT_GOAL := build

deps:
ifeq ($(UNAME_S),Darwin)
	@if [ -z "$(OBS_VERSION)" ]; then \
		echo "OBS.app not found at $(OBS_APP_BUNDLE) - install it with: brew install --cask obs"; \
		exit 1; \
	fi
	@mkdir -p "$(DEPS_DIR)/generated"
	@if [ ! -f "$(OBS_SRC_DIR)/libobs/obs.h" ]; then \
		rm -rf "$(OBS_SRC_DIR)"; \
		git clone --filter=blob:none --sparse --depth 1 --branch "$(OBS_VERSION)" \
			https://github.com/obsproject/obs-studio.git "$(OBS_SRC_DIR)"; \
		git -C "$(OBS_SRC_DIR)" sparse-checkout set libobs; \
	fi
	@ln -sfn "obs-studio-$(OBS_VERSION)/libobs" "$(DEPS_DIR)/libobs-headers"
	@printf '%s\n' \
		'#pragma once' \
		'/* #undef OBS_DATA_PATH */' \
		'/* #undef OBS_PLUGIN_PATH */' \
		'/* #undef OBS_PLUGIN_DESTINATION */' \
		'/* #undef GIO_FOUND */' \
		'/* #undef PULSEAUDIO_FOUND */' \
		'/* #undef XCB_XINPUT_FOUND */' \
		'/* #undef ENABLE_WAYLAND */' \
		'#define OBS_RELEASE_CANDIDATE 0' \
		'#define OBS_BETA 0' \
		> "$(DEPS_DIR)/generated/obsconfig.h"
endif

configure: deps
	cmake -B $(BUILD_DIR) -S . $(CMAKE_ARGS)

build: configure
	cmake --build $(BUILD_DIR) -j $(JOBS)

stage: build
	cmake --install $(BUILD_DIR) --prefix $(STAGE_DIR)
ifeq ($(UNAME_S),Darwin)
	mkdir -p "$(STAGE_DIR)/obs-plugins/$(PLUGIN_NAME).plugin/Contents/Resources"
	cp -R "$(STAGE_DIR)/data/obs-plugins/$(PLUGIN_NAME)/." "$(STAGE_DIR)/obs-plugins/$(PLUGIN_NAME).plugin/Contents/Resources/"
endif

install: stage
ifeq ($(UNAME_S),Darwin)
	mkdir -p "$(OBS_PLUGIN_DIR)"
	rm -rf "$(OBS_PLUGIN_DIR)/$(PLUGIN_NAME).plugin"
	cp -R "$(STAGE_DIR)/obs-plugins/$(PLUGIN_NAME).plugin" "$(OBS_PLUGIN_DIR)/"
else ifeq ($(UNAME_S),Linux)
	mkdir -p "$(OBS_PLUGIN_DIR)/$(PLUGIN_NAME)/bin/64bit"
	mkdir -p "$(OBS_PLUGIN_DIR)/$(PLUGIN_NAME)/data"
	cp "$(STAGE_DIR)/obs-plugins/$(PLUGIN_NAME).so" "$(OBS_PLUGIN_DIR)/$(PLUGIN_NAME)/bin/64bit/"
	cp -R "$(STAGE_DIR)/data/obs-plugins/$(PLUGIN_NAME)/." "$(OBS_PLUGIN_DIR)/$(PLUGIN_NAME)/data/"
else
	@echo "no automatic install for $(UNAME_S); staged files are in $(STAGE_DIR)"
endif

# Builds a distributable installer: a .dmg on macOS, a .deb on Linux.
package: stage
	@mkdir -p $(DIST_DIR)
ifeq ($(UNAME_S),Darwin)
	rm -f "$(DIST_DIR)/$(PLUGIN_NAME)-$(PLUGIN_VERSION)-macos.dmg"
	hdiutil create -volname "$(PLUGIN_NAME)" \
		-srcfolder "$(STAGE_DIR)/obs-plugins/$(PLUGIN_NAME).plugin" \
		-ov -format UDZO \
		"$(DIST_DIR)/$(PLUGIN_NAME)-$(PLUGIN_VERSION)-macos.dmg"
else ifeq ($(UNAME_S),Linux)
	rm -rf "$(BUILD_DIR)/deb"
	mkdir -p "$(BUILD_DIR)/deb/DEBIAN"
	mkdir -p "$(BUILD_DIR)/deb/usr/lib/x86_64-linux-gnu/obs-plugins"
	mkdir -p "$(BUILD_DIR)/deb/usr/share/obs/obs-plugins/$(PLUGIN_NAME)"
	cp "$(STAGE_DIR)/obs-plugins/$(PLUGIN_NAME).so" "$(BUILD_DIR)/deb/usr/lib/x86_64-linux-gnu/obs-plugins/"
	cp -R "$(STAGE_DIR)/data/obs-plugins/$(PLUGIN_NAME)/." "$(BUILD_DIR)/deb/usr/share/obs/obs-plugins/$(PLUGIN_NAME)/"
	printf '%s\n' \
		'Package: $(PLUGIN_NAME)' \
		'Version: $(PLUGIN_VERSION)' \
		'Architecture: amd64' \
		'Maintainer: $(PLUGIN_MAINTAINER)' \
		'Depends: obs-studio (>= 28.0.0)' \
		'Description: OBS filter that randomly shows one child source of a scene/group at a time.' \
		> "$(BUILD_DIR)/deb/DEBIAN/control"
	dpkg-deb --build --root-owner-group "$(BUILD_DIR)/deb" \
		"$(DIST_DIR)/$(PLUGIN_NAME)_$(PLUGIN_VERSION)_amd64.deb"
else
	@echo "no packaging support for $(UNAME_S)"
endif

# Cross-compiles for Windows from Linux/macOS via mingw-w64 - nothing is
# built on actual Windows. See deps-windows.sh and
# cmake/mingw-w64-toolchain.cmake.
deps-windows:
	./deps-windows.sh

configure-windows: deps-windows
	cmake -B $(WIN_BUILD_DIR) -S . -DCMAKE_TOOLCHAIN_FILE=cmake/mingw-w64-toolchain.cmake

build-windows: configure-windows
	cmake --build $(WIN_BUILD_DIR) -j $(JOBS)

stage-windows: build-windows
	cmake --install $(WIN_BUILD_DIR) --prefix $(WIN_STAGE_DIR)

# Builds a real Windows installer (.exe) via makensis - which, like the
# mingw-w64 compiler, cross-builds from Linux/macOS: nothing runs on actual
# Windows until the installer itself is executed there. See
# cmake/installer.nsi for what it installs and where.
package-windows: stage-windows
	@mkdir -p $(DIST_DIR)
	@command -v makensis >/dev/null || { \
		echo "makensis not found - install it with: brew install makensis (macOS/Linux; apt's nsis is too old, see CLAUDE.md)"; \
		exit 1; \
	}
	rm -f "$(DIST_DIR)/$(PLUGIN_NAME)-$(PLUGIN_VERSION)-windows-installer.exe"
	makensis \
		-DPLUGIN_NAME=$(PLUGIN_NAME) \
		-DPLUGIN_VERSION=$(PLUGIN_VERSION) \
		-DSTAGE_DIR=$(abspath $(WIN_STAGE_DIR)) \
		-DOUT_FILE=$(abspath $(DIST_DIR))/$(PLUGIN_NAME)-$(PLUGIN_VERSION)-windows-installer.exe \
		cmake/installer.nsi

clean-windows:
	rm -rf $(WIN_BUILD_DIR)

# Cuts a release: shows the current version, prompts for the next one (or
# takes it as `make release x.y.z`), bumps CMakeLists.txt, commits, and tags.
# Doesn't push. See bin/release.sh.
release:
	@bin/release.sh $(RELEASE_ARG)

# Monthly maintenance pass - see bin/maintenance.sh and
# .claude/skills/monthly-maintenance. Report-only: it never bumps anything
# itself. `maintenance` rebuilds every platform this host can build first,
# then runs both `outdated` (version checks) and `audit` (CVEs, static
# analysis, artifact hardening). Fails if any check FAILs.
maintenance:
	bin/maintenance.sh all

outdated:
	bin/maintenance.sh outdated

audit:
	bin/maintenance.sh audit

# Points git at the repo's versioned hooks (.githooks/) instead of the
# untracked, unshared .git/hooks/ - run once per clone.
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/*
	@echo "git hooks enabled (core.hooksPath -> .githooks)"

clean:
	rm -rf $(BUILD_DIR)

rebuild: clean build
