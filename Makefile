SHELL := /bin/bash
VERSION := $(shell tr -d '[:space:]' < VERSION)
ARCH := $(shell dpkg --print-architecture 2>/dev/null || echo amd64)
DIST_DIR := dist

.PHONY: all build check install uninstall install-no-deps source-archive deb releases cubic-installer screenshots clean

all: build

# The programs (GUI, maintenance tool, panel status, tray icon) are Rust.
build:
	cargo build --release --locked

check:
	./tests/run-tests.sh

install: build
	./install.sh

install-no-deps: build
	./install.sh --no-deps

uninstall:
	./uninstall.sh

source-archive: check
	mkdir -p $(DIST_DIR)
	tar --exclude='./.git' --exclude='./$(DIST_DIR)' --exclude='./target' \
		-czf $(DIST_DIR)/eduka-update-system-$(VERSION)-source.tar.gz \
		--transform='s,^\.,eduka-update-system-$(VERSION),' .

deb: build
	./packaging/build-deb.sh $(DIST_DIR)

# Refresh the downloadable package kept in the repository (releases/):
# one package under a stable name, used by tools/get-eus.sh.
releases: check build
	rm -f releases/*.deb releases/SHA256SUMS
	./packaging/build-deb.sh $(DIST_DIR)
	cp $(DIST_DIR)/eduka-update-system_$(VERSION)_$(ARCH).deb releases/eduka-update-system_$(ARCH).deb
	cd releases && sha256sum *.deb > SHA256SUMS

cubic-installer: build
	./tools/build-cubic-installer.sh

# English screenshots of every page (needs xvfb-run).
screenshots: build
	./tools/screenshots.sh

clean:
	cargo clean
	rm -rf -- $(DIST_DIR)
