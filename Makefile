SHELL := /bin/bash
VERSION := $(shell tr -d '[:space:]' < VERSION)
DIST_DIR := dist

.PHONY: all check install uninstall install-no-deps source-archive clean

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

clean:
	rm -rf -- $(DIST_DIR)
	find . -type d -name __pycache__ -prune -exec rm -rf -- {} +

