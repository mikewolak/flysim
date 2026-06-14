# FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
# Educational & academic research use only — commercial use prohibited.  See LICENSE.
#
#   make          → build FlySim.app (Debug)
#   make run      → build + launch
#   make release  → build + sign + notarize + DMG → ~/Desktop/
#   make clean    → wipe build artifacts
#
# Signing identity is developer-specific and NOT committed. Copy
# signing.env.template → signing.env and fill in your own values (gitignored).

VERSION := 0.3

# load signing identity (SIGN_IDENTITY / NOTARY_PROFILE_NAME) for `release`
-include signing.env
export SIGN_IDENTITY
export NOTARY_PROFILE_NAME

.PHONY: all run release clean

all:
	$(MAKE) -C app

run:
	$(MAKE) -C app run

release:
	@test -n "$(SIGN_IDENTITY)" || { echo "FAIL: SIGN_IDENTITY unset — copy signing.env.template → signing.env"; exit 1; }
	VERSION=$(VERSION) installer/release.sh

clean:
	$(MAKE) -C app clean
	rm -rf build/installer
