# VitaPresence for macOS. Run from this directory (or with `make -C mac`); `make help` lists the targets.
#
# Everything is built in BUILD_DIR, outside the repository: bundles built in an iCloud-synced folder fail
# codesign. Only `make zip` writes into the repository, to dist/.

BUILD_DIR ?= $(HOME)/Library/Caches/io.github.aegiosot.VitaPresence
SWIFT_FLAGS := --scratch-path "$(BUILD_DIR)/swiftpm"
BUILD_APP := VITAPRESENCE_BUILD_DIR="$(BUILD_DIR)" scripts/build-app.sh

.PHONY: build test app app-arm64 cli install run zip clean mock-vita help

build: ## Debug build of the app and the CLI
	swift build $(SWIFT_FLAGS)

test: ## Run the tests
	swift test $(SWIFT_FLAGS)

app: ## Universal (arm64 + x86_64) VitaPresence.app, ad hoc signed
	$(BUILD_APP) --arch universal

app-arm64: ## Apple silicon VitaPresence.app (quicker to build)
	$(BUILD_APP) --arch arm64

# macOS 27 shows the ARP cache only to programs signed with a reverse-DNS identifier. Without one,
# vitapresence-cli can't look up the Vita's IP address from its MAC address.
cli: ## Release build of vitapresence-cli, signed so it can resolve MAC addresses
	swift build $(SWIFT_FLAGS) -c release --product vitapresence-cli
	@cli="$$(swift build $(SWIFT_FLAGS) -c release --show-bin-path)/vitapresence-cli" && \
		codesign --force --sign - --identifier io.github.aegiosot.vitapresence-cli "$$cli" && \
		echo "Built $$cli"

install: ## Build the app and copy it to /Applications (or ~/Applications)
	$(BUILD_APP) --arch universal --install

run: app ## Build the app and open it
	open "$(BUILD_DIR)/VitaPresence.app"

zip: ## Build the app and zip it into dist/ for a release
	$(BUILD_APP) --arch universal --zip

clean: ## Delete the build products and dist/
	rm -rf "$(BUILD_DIR)/swiftpm" "$(BUILD_DIR)/work" "$(BUILD_DIR)/VitaPresence.app" dist

mock-vita: ## Pretend to be a Vita running the plugin, for trying the app without one
	python3 scripts/mock-vita.py

help: ## List the targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z0-9-]+:.*## / { printf "  %-10s %s\n", $$1, $$2 }' $(firstword $(MAKEFILE_LIST))
