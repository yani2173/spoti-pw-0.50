# Package the pinned official 0.51.0 kit. The only compiled source is our add-on.
IPA ?= $(firstword $(wildcard ipa/*.ipa))
.DEFAULT_GOAL := release-optimized

.PHONY: build release release-official release-optimized install log test
build release: release-optimized
release-official:
	./scripts/official-release.sh "$(IPA)"
release-optimized:
	SG_OPTIMIZE=1 ./scripts/official-release.sh "$(IPA)"
install: release-optimized
	./scripts/install.sh out/spoti.pw-0.51.0-optimized.ipa
log:
	./scripts/dump-log.sh
test:
	python3 -m unittest discover -s tests -v
