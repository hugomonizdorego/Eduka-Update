SHELL := /bin/bash
VERSION := $(shell tr -d '[:space:]' < VERSION)
DIST_DIR := dist

.PHONY: all check install uninstall install-no-deps source-archive deb releases cubic-installer clean

all: check

check:
	./tests/run-tests.sh

install:
	./install.sh

install-no-deps:
	./install.sh --no-deps

uninstall:
	./uninstall.sh

source-archive: check
	mkdir -p $(DIST_DIR)
	tar --exclude='./.git' --exclude='./$(DIST_DIR)' \
		-czf $(DIST_DIR)/eduka-update-system-$(VERSION)-source.tar.gz \
		--transform='s,^\.,eduka-update-system-$(VERSION),' .

deb:
	./packaging/build-deb.sh $(DIST_DIR)

# Refresh the downloadable package kept in the repository (releases/).
releases: check
	rm -f releases/*.deb releases/SHA256SUMS
	./packaging/build-deb.sh releases
	cp releases/eduka-update-system_$(VERSION)_all.deb releases/eduka-update-system_all.deb
	cd releases && sha256sum *.deb > SHA256SUMS

cubic-installer:
	./tools/build-cubic-installer.sh

clean:
	rm -rf -- $(DIST_DIR)
	find . -type d -name __pycache__ -prune -exec rm -rf -- {} +

