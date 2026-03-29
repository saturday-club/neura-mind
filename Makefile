# NeuraMind — Build & Development Makefile
# Usage: make <target>
# Run `make help` to see all available targets.

PRODUCT     := NeuraMind
BUNDLE_ID   := com.neuramind.app
VERSION     := 0.2.0
BUILD_NUMBER := 1
BUILD_DIR   := .build
DIST_DIR    := dist
ARCH        := $(shell uname -m)
DEBUG_BIN   := $(BUILD_DIR)/debug/$(PRODUCT)
RELEASE_BIN := $(BUILD_DIR)/release/$(PRODUCT)
APP_BUNDLE  := $(BUILD_DIR)/$(PRODUCT).app
RELEASE_APP_BUNDLE := $(DIST_DIR)/$(PRODUCT).app
DMG_STAGING_DIR := $(DIST_DIR)/$(PRODUCT)-dmg
DMG_FILE    := $(DIST_DIR)/$(PRODUCT)-$(VERSION)-$(ARCH).dmg
DB_PATH     := $(HOME)/Library/Application Support/NeuraMind/neuramind.sqlite
SIGN_ID     := Apple Development: saaivignesh20@gmail.com (F7Q59S24D2)
ICON_SOURCE := Resources/contextd.icns
ICON_BUNDLE_NAME := neuramind.icns
CLANG_MODULE_CACHE := $(CURDIR)/$(BUILD_DIR)/clang-module-cache
SWIFTPM_MODULE_CACHE := $(CURDIR)/$(BUILD_DIR)/swiftpm-module-cache
SWIFT_ENV := CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE)" SWIFTPM_MODULECACHE_OVERRIDE="$(SWIFTPM_MODULE_CACHE)"

# Colors
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
RESET  := \033[0m

.PHONY: help build release run clean resolve lint test benchmark db-shell db-stats db-recent db-search \
        db-keyframes reset-permissions reset-db logs install install-app uninstall check-permissions watch \
        setup-cert ensure-debug-bin bundle bundle-release run-bundle dmg

# Sign a bundle: tries SIGN_ID cert first, falls back to ad-hoc.
# Using a stable cert preserves macOS permissions (Screen Recording, Accessibility)
# across rebuilds. Ad-hoc signing generates a new identity each time, which resets them.
define sign_bundle
	@if codesign --force --deep --sign "$(SIGN_ID)" \
		--entitlements Resources/NeuraMind.entitlements \
		$(1) 2>/dev/null; then \
		echo "  $(GREEN)Signed with $(SIGN_ID)$(RESET)"; \
	else \
		codesign --force --deep --sign - \
			--entitlements Resources/NeuraMind.entitlements \
			$(1) 2>/dev/null; \
		echo "  $(YELLOW)Ad-hoc signed (run 'make setup-cert' once to preserve permissions across rebuilds)$(RESET)"; \
	fi
endef

# ─────────────────────────────────────────
#  Help
# ─────────────────────────────────────────

help: ## Show this help
	@echo "$(CYAN)NeuraMind Development Commands$(RESET)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─────────────────────────────────────────
#  Build
# ─────────────────────────────────────────

build: ## Build debug binary
	@echo "$(CYAN)Building debug...$(RESET)"
	@mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"
	@$(SWIFT_ENV) swift build 2>&1
	@echo "$(GREEN)Build complete: $(DEBUG_BIN)$(RESET)"

release: ## Build optimized release binary
	@echo "$(CYAN)Building release...$(RESET)"
	@mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"
	@$(SWIFT_ENV) swift build -c release 2>&1
	@echo "$(GREEN)Release build complete: $(RELEASE_BIN)$(RESET)"

resolve: ## Resolve Swift package dependencies
	@echo "$(CYAN)Resolving packages...$(RESET)"
	@mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"
	@$(SWIFT_ENV) swift package resolve

clean: ## Remove build artifacts
	@echo "$(YELLOW)Cleaning build directory...$(RESET)"
	@mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"
	@$(SWIFT_ENV) swift package clean
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DIST_DIR)
	@echo "$(GREEN)Clean.$(RESET)"

# ─────────────────────────────────────────
#  Run
# ─────────────────────────────────────────

run: install-app ## Build, install to /Applications, and launch (preserves permissions)

run-debug: build ## Run raw debug binary (no macOS permissions — for quick iteration)
	@echo "$(CYAN)Running NeuraMind (raw binary, no permissions)...$(RESET)"
	@echo "$(YELLOW)Press Ctrl+C to stop$(RESET)"
	@$(DEBUG_BIN)

run-release: release ## Build and run (release)
	@echo "$(CYAN)Running NeuraMind (release)...$(RESET)"
	@$(RELEASE_BIN)

# ─────────────────────────────────────────
#  Development
# ─────────────────────────────────────────

watch: ## Rebuild on file changes (requires fswatch: brew install fswatch)
	@command -v fswatch >/dev/null 2>&1 || { echo "$(RED)fswatch not found. Install with: brew install fswatch$(RESET)"; exit 1; }
	@echo "$(CYAN)Watching for changes... (Ctrl+C to stop)$(RESET)"
	@fswatch -o -r NeuraMind/ --include '\.swift$$' --exclude '.*' | while read -r _; do \
		echo ""; \
		echo "$(YELLOW)Change detected, rebuilding...$(RESET)"; \
		mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"; \
		$(SWIFT_ENV) swift build 2>&1; \
		if [ $$? -eq 0 ]; then \
			echo "$(GREEN)Build succeeded$(RESET)"; \
		else \
			echo "$(RED)Build failed$(RESET)"; \
		fi; \
	done

test: ## Run unit tests
	@echo "$(CYAN)Running tests...$(RESET)"
	@mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"
	@$(SWIFT_ENV) swift test 2>&1
	@echo "$(GREEN)Tests complete.$(RESET)"

benchmark: ## Run ImageDiffer benchmarks (scalar vs SIMD)
	@echo "$(CYAN)Running ImageDiffer benchmarks...$(RESET)"
	@mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"
	@$(SWIFT_ENV) swift test --filter "ImageDifferTests/testBenchmark" 2>&1
	@echo "$(GREEN)Benchmarks complete.$(RESET)"

lint: ## Check for common issues (unused imports, formatting)
	@echo "$(CYAN)Checking for issues...$(RESET)"
	@echo "--- Unused variables ---"
	@mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"
	@$(SWIFT_ENV) swift build 2>&1 | grep -i "warning:" || echo "  No warnings."
	@echo ""
	@echo "--- TODO/FIXME markers ---"
	@grep -rn "TODO\|FIXME\|HACK\|XXX" NeuraMind/ --include="*.swift" || echo "  None found."
	@echo ""
	@echo "--- File sizes ---"
	@find NeuraMind -name "*.swift" -exec wc -l {} + | sort -rn | head -15

loc: ## Count lines of code
	@echo "$(CYAN)Lines of code:$(RESET)"
	@find NeuraMind -name "*.swift" -exec cat {} + | wc -l | xargs echo "  Total Swift lines:"
	@echo ""
	@echo "$(CYAN)By directory:$(RESET)"
	@for dir in App Capture Storage Summarization Enrichment LLMClient UI Permissions Utilities; do \
		count=$$(find NeuraMind/$$dir -name "*.swift" -exec cat {} + 2>/dev/null | wc -l | tr -d ' '); \
		printf "  %-20s %s lines\n" "$$dir/" "$$count"; \
	done

# ─────────────────────────────────────────
#  Database
# ─────────────────────────────────────────

db-shell: ## Open SQLite shell on the NeuraMind database
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Opening database: $(DB_PATH)$(RESET)"; \
		sqlite3 "$(DB_PATH)"; \
	else \
		echo "$(RED)Database not found at: $(DB_PATH)$(RESET)"; \
		echo "Run the app first to create the database."; \
	fi

db-stats: ## Show database statistics (row counts, size)
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Database: $(DB_PATH)$(RESET)"; \
		SIZE=$$(ls -lh "$(DB_PATH)" | awk '{print $$5}'); \
		echo "  Size: $$SIZE"; \
		echo ""; \
		echo "$(CYAN)Row counts:$(RESET)"; \
		sqlite3 "$(DB_PATH)" "SELECT '  captures:   ' || COUNT(*) FROM captures; \
			SELECT '  keyframes:  ' || COUNT(*) FROM captures WHERE frameType = 'keyframe'; \
			SELECT '  deltas:     ' || COUNT(*) FROM captures WHERE frameType = 'delta'; \
			SELECT '  summaries:  ' || COUNT(*) FROM summaries; \
			SELECT '  summarized: ' || COUNT(*) FROM captures WHERE isSummarized = 1;"; \
		echo ""; \
		echo "$(CYAN)Time range:$(RESET)"; \
		sqlite3 "$(DB_PATH)" "SELECT '  Oldest: ' || datetime(MIN(timestamp), 'unixepoch', 'localtime') FROM captures; \
			SELECT '  Newest: ' || datetime(MAX(timestamp), 'unixepoch', 'localtime') FROM captures;"; \
		echo ""; \
		echo "$(CYAN)Top apps:$(RESET)"; \
		sqlite3 "$(DB_PATH)" "SELECT '  ' || appName || ': ' || COUNT(*) FROM captures GROUP BY appName ORDER BY COUNT(*) DESC LIMIT 10;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-recent: ## Show the 10 most recent captures
	@if [ -f "$(DB_PATH)" ]; then \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT id, datetime(timestamp, 'unixepoch', 'localtime') AS time, \
			frameType AS type, appName AS app, \
			substr(fullOcrText, 1, 80) AS text_preview \
			FROM captures ORDER BY timestamp DESC LIMIT 10;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-summaries: ## Show the 10 most recent summaries
	@if [ -f "$(DB_PATH)" ]; then \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT id, \
			datetime(startTimestamp, 'unixepoch', 'localtime') AS start, \
			datetime(endTimestamp, 'unixepoch', 'localtime') AS end, \
			appNames AS apps, \
			substr(summary, 1, 100) AS summary_preview \
			FROM summaries ORDER BY endTimestamp DESC LIMIT 10;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-search: ## Full-text search captures (usage: make db-search Q="search term")
	@if [ -z "$(Q)" ]; then \
		echo "$(RED)Usage: make db-search Q=\"search term\"$(RESET)"; \
		exit 1; \
	fi
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Searching for: $(Q)$(RESET)"; \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT captures.id, datetime(captures.timestamp, 'unixepoch', 'localtime') AS time, \
			captures.appName AS app, captures.windowTitle AS window, \
			substr(captures.fullOcrText, 1, 120) AS text_preview \
			FROM captures \
			JOIN captures_fts ON captures.id = captures_fts.rowid \
			WHERE captures_fts MATCH '\"$(Q)\"' \
			ORDER BY rank LIMIT 20;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-search-summaries: ## Full-text search summaries (usage: make db-search-summaries Q="search term")
	@if [ -z "$(Q)" ]; then \
		echo "$(RED)Usage: make db-search-summaries Q=\"search term\"$(RESET)"; \
		exit 1; \
	fi
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Searching summaries for: $(Q)$(RESET)"; \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT summaries.id, \
			datetime(summaries.startTimestamp, 'unixepoch', 'localtime') AS start, \
			summaries.appNames AS apps, \
			substr(summaries.summary, 1, 150) AS summary_preview \
			FROM summaries \
			JOIN summaries_fts ON summaries.id = summaries_fts.rowid \
			WHERE summaries_fts MATCH '\"$(Q)\"' \
			ORDER BY rank LIMIT 20;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-keyframes: ## Show keyframes with delta counts
	@if [ -f "$(DB_PATH)" ]; then \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT k.id, datetime(k.timestamp, 'unixepoch', 'localtime') AS time, \
			k.appName AS app, COUNT(d.id) AS deltas, \
			substr(k.fullOcrText, 1, 80) AS text_preview \
			FROM captures k LEFT JOIN captures d ON d.keyframeId = k.id \
			WHERE k.frameType = 'keyframe' \
			GROUP BY k.id ORDER BY k.timestamp DESC LIMIT 20;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

# ─────────────────────────────────────────
#  Permissions & Reset
# ─────────────────────────────────────────

check-permissions: ## Check if required macOS permissions are granted
	@echo "$(CYAN)Checking permissions for NeuraMind...$(RESET)"
	@echo ""
	@echo "Screen Recording:"
	@if sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
		"SELECT allowed FROM access WHERE service='kTCCServiceScreenCapture' AND client='$(BUNDLE_ID)'" 2>/dev/null | grep -q 1; then \
		echo "  $(GREEN)Granted$(RESET)"; \
	else \
		echo "  $(YELLOW)Not granted (or cannot read TCC database — this is normal)$(RESET)"; \
		echo "  Check: System Settings > Privacy & Security > Screen Recording"; \
	fi
	@echo ""
	@echo "Accessibility:"
	@if sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
		"SELECT allowed FROM access WHERE service='kTCCServiceAccessibility' AND client='$(BUNDLE_ID)'" 2>/dev/null | grep -q 1; then \
		echo "  $(GREEN)Granted$(RESET)"; \
	else \
		echo "  $(YELLOW)Not granted (or cannot read TCC database — this is normal)$(RESET)"; \
		echo "  Check: System Settings > Privacy & Security > Accessibility"; \
	fi

reset-permissions: ## Reset Screen Recording and Accessibility permissions (requires restart)
	@echo "$(YELLOW)Resetting permissions for $(BUNDLE_ID)...$(RESET)"
	@tccutil reset ScreenCapture $(BUNDLE_ID) 2>/dev/null || true
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null || true
	@echo "$(GREEN)Permissions reset. Restart the app to re-trigger permission prompts.$(RESET)"

reset-db: ## Delete the local database (destructive!)
	@echo "$(RED)This will delete all captured data!$(RESET)"
	@read -p "Are you sure? (y/N) " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -f "$(DB_PATH)"; \
		rm -f "$(DB_PATH)-wal"; \
		rm -f "$(DB_PATH)-shm"; \
		echo "$(GREEN)Database deleted.$(RESET)"; \
	else \
		echo "Cancelled."; \
	fi

# ─────────────────────────────────────────
#  Logs
# ─────────────────────────────────────────

logs: ## Stream NeuraMind logs from unified logging (live)
	@echo "$(CYAN)Streaming logs for com.neuramind.app... (Ctrl+C to stop)$(RESET)"
	@log stream --predicate 'subsystem == "com.neuramind.app"' --style compact

logs-recent: ## Show recent NeuraMind log entries
	@echo "$(CYAN)Recent logs for com.neuramind.app:$(RESET)"
	@log show --predicate 'subsystem == "com.neuramind.app"' --style compact --last 5m

logs-errors: ## Show only error-level log entries
	@echo "$(RED)Error logs for com.neuramind.app:$(RESET)"
	@log show --predicate 'subsystem == "com.neuramind.app" AND messageType == error' --style compact --last 1h

# ─────────────────────────────────────────
#  App Bundle (for proper permissions)
# ─────────────────────────────────────────

bundle: ensure-debug-bin ## Create a .app bundle (needed for proper permission prompts)
	@echo "$(CYAN)Creating app bundle...$(RESET)"
	@killall $(PRODUCT) 2>/dev/null || true
	@sleep 0.5
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp $(DEBUG_BIN) "$(APP_BUNDLE)/Contents/MacOS/$(PRODUCT)"
	@PRODUCT_NAME="$(PRODUCT)" \
	PRODUCT_EXECUTABLE="$(PRODUCT)" \
	BUNDLE_ID="$(BUNDLE_ID)" \
	APP_VERSION="$(VERSION)" \
	APP_BUILD="$(BUILD_NUMBER)" \
	ICON_BASENAME="$(basename $(ICON_BUNDLE_NAME))" \
	./scripts/gen-info-plist.sh > "$(APP_BUNDLE)/Contents/Info.plist"
	@if [ -f "$(ICON_SOURCE)" ]; then \
		cp "$(ICON_SOURCE)" "$(APP_BUNDLE)/Contents/Resources/$(ICON_BUNDLE_NAME)"; \
		echo "  $(GREEN)Icon installed$(RESET)"; \
	fi
	@$(call sign_bundle,$(APP_BUNDLE))
	@echo "$(GREEN)App bundle created: $(APP_BUNDLE)$(RESET)"

bundle-release: release ## Create a signed release .app bundle in dist/
	@echo "$(CYAN)Creating release app bundle...$(RESET)"
	@rm -rf "$(RELEASE_APP_BUNDLE)"
	@mkdir -p "$(RELEASE_APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(RELEASE_APP_BUNDLE)/Contents/Resources"
	@cp "$(RELEASE_BIN)" "$(RELEASE_APP_BUNDLE)/Contents/MacOS/$(PRODUCT)"
	@PRODUCT_NAME="$(PRODUCT)" \
	PRODUCT_EXECUTABLE="$(PRODUCT)" \
	BUNDLE_ID="$(BUNDLE_ID)" \
	APP_VERSION="$(VERSION)" \
	APP_BUILD="$(BUILD_NUMBER)" \
	ICON_BASENAME="$(basename $(ICON_BUNDLE_NAME))" \
	./scripts/gen-info-plist.sh > "$(RELEASE_APP_BUNDLE)/Contents/Info.plist"
	@if [ -f "$(ICON_SOURCE)" ]; then \
		cp "$(ICON_SOURCE)" "$(RELEASE_APP_BUNDLE)/Contents/Resources/$(ICON_BUNDLE_NAME)"; \
		echo "  $(GREEN)Icon installed$(RESET)"; \
	fi
	@$(call sign_bundle,$(RELEASE_APP_BUNDLE))
	@echo "$(GREEN)Release app bundle created: $(RELEASE_APP_BUNDLE)$(RESET)"

run-bundle: bundle ## Build app bundle and launch it
	@echo "$(CYAN)Launching $(APP_BUNDLE)...$(RESET)"
	@open "$(APP_BUNDLE)"

dmg: bundle-release ## Create a distributable DMG for Homebrew cask releases
	@echo "$(CYAN)Packaging DMG...$(RESET)"
	@rm -rf "$(DMG_STAGING_DIR)"
	@mkdir -p "$(DMG_STAGING_DIR)"
	@ditto "$(RELEASE_APP_BUNDLE)" "$(DMG_STAGING_DIR)/$(PRODUCT).app"
	@ln -s /Applications "$(DMG_STAGING_DIR)/Applications"
	@rm -f "$(DMG_FILE)"
	@hdiutil create \
		-volname "$(PRODUCT)" \
		-srcfolder "$(DMG_STAGING_DIR)" \
		-fs HFS+ \
		-format UDZO \
		-imagekey zlib-level=9 \
		"$(DMG_FILE)" >/dev/null
	@echo "$(GREEN)DMG created: $(DMG_FILE)$(RESET)"
	@echo "$(CYAN)SHA256:$(RESET)"
	@shasum -a 256 "$(DMG_FILE)"

# ─────────────────────────────────────────
#  Install
# ─────────────────────────────────────────

install: release ## Install release binary to /usr/local/bin
	@echo "$(CYAN)Installing to /usr/local/bin/$(PRODUCT)...$(RESET)"
	@cp $(RELEASE_BIN) /usr/local/bin/$(PRODUCT)
	@echo "$(GREEN)Installed. Run with: $(PRODUCT)$(RESET)"

INSTALLED_APP := /Applications/NeuraMind.app

install-app: build ## Build, install to /Applications/NeuraMind.app, and launch (preserves permissions)
	@echo "$(CYAN)Installing to $(INSTALLED_APP)...$(RESET)"
	@killall $(PRODUCT) 2>/dev/null || true
	@sleep 0.5
	@mkdir -p "$(INSTALLED_APP)/Contents/MacOS"
	@mkdir -p "$(INSTALLED_APP)/Contents/Resources"
	@cp $(DEBUG_BIN) "$(INSTALLED_APP)/Contents/MacOS/$(PRODUCT)"
	@PRODUCT_NAME="$(PRODUCT)" \
	PRODUCT_EXECUTABLE="$(PRODUCT)" \
	BUNDLE_ID="$(BUNDLE_ID)" \
	APP_VERSION="$(VERSION)" \
	APP_BUILD="$(BUILD_NUMBER)" \
	ICON_BASENAME="$(basename $(ICON_BUNDLE_NAME))" \
	./scripts/gen-info-plist.sh > "$(INSTALLED_APP)/Contents/Info.plist"
	@if [ -f "$(ICON_SOURCE)" ]; then \
		cp "$(ICON_SOURCE)" "$(INSTALLED_APP)/Contents/Resources/$(ICON_BUNDLE_NAME)"; \
	fi
	$(call sign_bundle,$(INSTALLED_APP))
	@echo "$(GREEN)Installed. Launching...$(RESET)"
	@open "$(INSTALLED_APP)"

uninstall: ## Remove installed binary
	@rm -f /usr/local/bin/$(PRODUCT)
	@echo "$(GREEN)Uninstalled.$(RESET)"

setup-cert: ## One-time: create a self-signed cert for code signing (preserves macOS permissions across rebuilds)
	@if security find-certificate -c "$(SIGN_ID)" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then \
		echo "$(GREEN)Certificate '$(SIGN_ID)' already exists. Nothing to do.$(RESET)"; \
	else \
		echo "$(CYAN)Creating self-signed certificate '$(SIGN_ID)'...$(RESET)"; \
		printf '%s\n' \
			'[ req ]' \
			'default_bits = 2048' \
			'distinguished_name = dn' \
			'x509_extensions = codesign' \
			'prompt = no' \
			'[ dn ]' \
			'CN = $(SIGN_ID)' \
			'[ codesign ]' \
			'keyUsage = digitalSignature' \
			'extendedKeyUsage = codeSigning' \
			> /tmp/neuramind-cert.conf && \
		openssl req -x509 -newkey rsa:2048 -nodes \
			-keyout /tmp/neuramind-cert.key \
			-out /tmp/neuramind-cert.pem \
			-days 3650 -config /tmp/neuramind-cert.conf 2>/dev/null && \
		openssl pkcs12 -export -inkey /tmp/neuramind-cert.key \
			-in /tmp/neuramind-cert.pem \
			-out /tmp/neuramind-cert.p12 \
			-legacy \
			-passout pass:neuramind-cert -name "$(SIGN_ID)" 2>/dev/null && \
		security import /tmp/neuramind-cert.p12 \
			-k ~/Library/Keychains/login.keychain-db \
			-P neuramind-cert \
			-T /usr/bin/codesign 2>/dev/null && \
		rm -f /tmp/neuramind-cert.conf /tmp/neuramind-cert.key /tmp/neuramind-cert.pem /tmp/neuramind-cert.p12 && \
		echo "$(GREEN)Certificate '$(SIGN_ID)' created and imported.$(RESET)" && \
		echo "$(YELLOW)You may need to open Keychain Access, find '$(SIGN_ID)', and set Trust → Code Signing → Always Trust.$(RESET)"; \
	fi
# Ensure a debug build exists before packaging it into an app bundle.
ensure-debug-bin:
	@if [ ! -x "$(DEBUG_BIN)" ]; then \
		echo "$(YELLOW)Debug binary not found at $(DEBUG_BIN). Running swift build first...$(RESET)"; \
		mkdir -p "$(CLANG_MODULE_CACHE)" "$(SWIFTPM_MODULE_CACHE)"; \
		$(SWIFT_ENV) swift build 2>&1 || exit $$?; \
	fi
