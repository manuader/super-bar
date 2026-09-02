# SuperBar — build automation. Requires Xcode 16+ and XcodeGen (brew install xcodegen).
PROJECT      := SuperBar.xcodeproj
SCHEME       := SuperBar
DERIVED      := build/DerivedData
CONFIG       ?= Debug
APP          := $(DERIVED)/Build/Products/$(CONFIG)/SuperBar.app
# Signing: an "Apple Development" identity gives the app a stable code
# identity, so macOS keeps the Accessibility grant across rebuilds. Without one
# the build is ad-hoc signed ("-") and the grant must be renewed after rebuilds.
CODE_SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development' && echo "Apple Development" || echo "-")
DEVELOPMENT_TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')
export CODE_SIGN_IDENTITY DEVELOPMENT_TEAM

.PHONY: help setup project test build release run install snapshot clean icon lint

help:
	@echo "make setup     - install XcodeGen via Homebrew"
	@echo "make test      - run SuperBarKit unit tests"
	@echo "make build     - generate the project and build a Debug app"
	@echo "make release   - build a Release app into build/SuperBar.app"
	@echo "make run       - build and launch the app"
	@echo "make install   - copy the Release app to /Applications"
	@echo "make snapshot  - render palette PNGs from fixture data into snapshots/"
	@echo "make icon      - regenerate the app icon"

setup:
	@command -v xcodegen >/dev/null || brew install xcodegen

project:
	@xcodegen generate --quiet

test:
	@swift test --package-path Packages/SuperBarKit 2>&1 | tail -30

build: project
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED) \
		-quiet build 2>&1 | grep -E "error:|warning: (unused|never)|BUILD" || true
	@test -d "$(APP)" && echo "Built $(APP)"

release:
	@$(MAKE) build CONFIG=Release
	@rm -rf build/SuperBar.app && cp -R $(DERIVED)/Build/Products/Release/SuperBar.app build/SuperBar.app
	@echo "Release app: build/SuperBar.app"

run: build
	@pkill -x SuperBar 2>/dev/null || true
	@open "$(APP)"

install: release
	@pkill -x SuperBar 2>/dev/null || true
	@rm -rf /Applications/SuperBar.app && cp -R build/SuperBar.app /Applications/SuperBar.app
	@open /Applications/SuperBar.app
	@echo "Installed /Applications/SuperBar.app"

snapshot: build
	@mkdir -p snapshots
	@scripts/snapshot.sh "$(APP)" snapshots

icon:
	@swift scripts/make-icon.swift App/SuperBar/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	@rm -rf build $(PROJECT) Packages/SuperBarKit/.build snapshots
