# FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
# Educational & academic research use only — commercial use prohibited.  See LICENSE.
# Makefile — FlySim.app (native macOS Obj-C + C99 LIF core)
# Builds build/FlySim.app. Requires only Xcode Command Line Tools.

APP_NAME   = FlySim
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
BINARY     = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
OBJ_DIR    = $(BUILD_DIR)/obj

CORE_DIR   = ../src
DATA_BIN   = ../data/flysim_real.bin
SYNTH_BIN  = ../data/flysim.bin

CC      = clang
CFLAGS  = -Wall -Wextra -O2 -fobjc-arc -I$(CORE_DIR) -Isrc -mmacosx-version-min=11.0
CSTD    = -std=c99
LDFLAGS = -framework Cocoa -framework QuartzCore -framework Metal -framework Foundation \
          -framework SceneKit

SRC_C = $(CORE_DIR)/flysim.c
SRC_M = src/main.m src/AppDelegate.m src/MainWindowController.m \
        src/FlyController.m src/FSWidgets.m src/FSControlServer.m \
        src/FlightView.m

OBJS = $(patsubst %.c,$(OBJ_DIR)/%.o,$(notdir $(SRC_C))) \
       $(OBJ_DIR)/flysim_metal.o \
       $(patsubst %.m,$(OBJ_DIR)/%.o,$(notdir $(SRC_M)))

.PHONY: all run clean bin
all: $(APP_BUNDLE)

$(APP_BUNDLE): $(BINARY) Resources/Info.plist bin
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns 2>/dev/null || true
	@cp $(DATA_BIN)  $(APP_BUNDLE)/Contents/Resources/flysim_real.bin 2>/dev/null || true
	@cp $(SYNTH_BIN) $(APP_BUNDLE)/Contents/Resources/flysim.bin 2>/dev/null || true
	@echo "Built $(APP_BUNDLE)"

$(BINARY): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(OBJS) $(LDFLAGS) -o $@

# core C
$(OBJ_DIR)/flysim.o: $(CORE_DIR)/flysim.c
	@mkdir -p $(OBJ_DIR)
	$(CC) $(CFLAGS) $(CSTD) -c $< -o $@

# core Obj-C (Metal backend)
$(OBJ_DIR)/flysim_metal.o: $(CORE_DIR)/flysim_metal.m
	@mkdir -p $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# Obj-C
$(OBJ_DIR)/%.o: src/%.m
	@mkdir -p $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# ensure the synthetic connectome exists (data/ is gitignored, so on a fresh
# checkout — e.g. CI — the directory may not exist yet; create it before packing)
bin:
	@if [ ! -f $(DATA_BIN) ]; then \
		echo "Generating synthetic connectome..."; \
		mkdir -p $(dir $(DATA_BIN)); \
		clang $(CSTD) -O2 ../tools/flypack.c -o $(BUILD_DIR)/flypack && \
		$(BUILD_DIR)/flypack synth $(DATA_BIN); \
	fi

run: all
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR)
