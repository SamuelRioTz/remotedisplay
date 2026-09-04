APP_NAME    = RemoteDisplayServer
BUNDLE_NAME = Remote Display Server
OUT_DIR     = .build
BUILD_DIR   = .build/apple/Products/Release
BINARY      = $(BUILD_DIR)/$(APP_NAME)
APP_BUNDLE  = $(OUT_DIR)/$(BUNDLE_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents
MACOS_DIR   = $(CONTENTS)/MacOS
RES_DIR     = $(CONTENTS)/Resources
INFO_PLIST  = Info.plist

# The engine binary (server, no flutter). Built separately with:
#   cargo build --release --bin rustdesk   (in the fork)
# Copied into the bundle as remotedisplayd.
ENGINE_BIN ?= $(HOME)/dev/rustdesk/target/release/rustdesk

# STABLE signing identity (TCC permissions survive rebuilds), chosen by TEAM through
# sign-identity.sh: Sam's personal team only (Developer ID Application if present,
# else Apple Development). Never the first "Apple Development" match — on this Mac
# that was the certificate of another organisation. Stable signing + SAME identity for
# app and engine = a single permission that persists. Override with SIGN_ID=... or TEAM_ID=...
TEAM_ID ?= K45698KZ4W
SIGN_ID ?= $(shell ./sign-identity.sh $(TEAM_ID))
CODE_ID := app.remotedisplay.server

.PHONY: all build bundle sign run clean

all: sign

build:
	@swift build -c release --arch arm64 --arch x86_64

bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@cp "$(BINARY)" "$(MACOS_DIR)/$(APP_NAME)"
	@test -x "$(ENGINE_BIN)" || { echo "ERROR: ENGINE_BIN=$(ENGINE_BIN) does not exist (build the engine first)"; exit 1; }
	@cp "$(ENGINE_BIN)" "$(MACOS_DIR)/remotedisplayd"
	@chmod +x "$(MACOS_DIR)/remotedisplayd"
	@cp "$(INFO_PLIST)" "$(CONTENTS)/Info.plist"
	@test -f AppIcon.icns && cp AppIcon.icns "$(RES_DIR)/AppIcon.icns" || true
	@echo "Built $(APP_BUNDLE)"

sign: bundle
ifeq ($(strip $(SIGN_ID)),)
	@echo "WARNING: no stable identity — ad-hoc signing (TCC permissions are invalidated on every rebuild)"
	@codesign --sign - --options runtime --entitlements Entitlements.plist --force --deep "$(APP_BUNDLE)"
else
	@echo "Signing with stable identity: $(SIGN_ID)  (id=$(CODE_ID))"
	@codesign --sign "$(SIGN_ID)" --identifier "$(CODE_ID)" --options runtime --entitlements Entitlements.plist --force "$(MACOS_DIR)/remotedisplayd"
	@codesign --sign "$(SIGN_ID)" --identifier "$(CODE_ID)" --options runtime --entitlements Entitlements.plist --force "$(MACOS_DIR)/$(APP_NAME)"
	@codesign --sign "$(SIGN_ID)" --identifier "$(CODE_ID)" --options runtime --entitlements Entitlements.plist --force "$(APP_BUNDLE)"
endif
	@xattr -dr com.apple.quarantine "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "Signed $(APP_BUNDLE)"

run: sign
	@open "$(APP_BUNDLE)"

clean:
	@rm -rf $(OUT_DIR)
