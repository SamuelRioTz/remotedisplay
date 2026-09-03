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

# El binario del motor (server, sin flutter). Se compila aparte con:
#   cargo build --release --bin rustdesk   (en el fork)
# Se copia dentro del bundle como remotedisplayd.
ENGINE_BIN ?= $(HOME)/dev/rustdesk/target/release/rustdesk

# Identidad de firma ESTABLE (permisos TCC sobreviven rebuilds). Prioridad:
# cert propio remotedisplay-cs > Apple Development (de Xcode/cuenta Apple) > ad-hoc.
# Firma estable + MISMA identidad en app y motor = un solo permiso que persiste.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -oE "remotedisplay-cs|RemoteDisplaySign" | head -1)
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
endif
CODE_ID := app.remotedisplay.server

.PHONY: all build bundle sign run clean

all: sign

build:
	@swift build -c release --arch arm64 --arch x86_64

bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@cp "$(BINARY)" "$(MACOS_DIR)/$(APP_NAME)"
	@test -x "$(ENGINE_BIN)" || { echo "ERROR: no existe ENGINE_BIN=$(ENGINE_BIN) (compila el motor primero)"; exit 1; }
	@cp "$(ENGINE_BIN)" "$(MACOS_DIR)/remotedisplayd"
	@chmod +x "$(MACOS_DIR)/remotedisplayd"
	@cp "$(INFO_PLIST)" "$(CONTENTS)/Info.plist"
	@test -f AppIcon.icns && cp AppIcon.icns "$(RES_DIR)/AppIcon.icns" || true
	@echo "Built $(APP_BUNDLE)"

sign: bundle
ifeq ($(strip $(SIGN_ID)),)
	@echo "AVISO: sin identidad estable — firma ad-hoc (permisos TCC se invalidan en cada rebuild)"
	@codesign --sign - --options runtime --entitlements Entitlements.plist --force --deep "$(APP_BUNDLE)"
else
	@echo "Firmando con identidad estable: $(SIGN_ID)  (id=$(CODE_ID))"
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
