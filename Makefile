# Image-Fabrik. Läuft mit GNU Make 3.81 (macOS) und neuer.
#
#   make build IMAGE=<name>   Image für alle Plattformen aus image.yaml bauen
#   make test IMAGE=<name>    bauen und testen
#   make test-all             alle Images in Stammbaum-Reihenfolge bauen und testen
#   make scan IMAGE=<name>    SBOM (syft) und CVE-Scan (trivy + vex.json) für gebaute Images
#   make list                 Images in Stammbaum-Reihenfolge anzeigen

SHELL := /bin/bash
IMAGE ?=
IMAGES := $(shell shared/scripts/image-meta.sh order)

.PHONY: build test test-all scan list require-image

build: require-image
	shared/scripts/build-image.sh $(IMAGE)

test: build
	shared/tests/test-image.sh $(IMAGE)

test-all:
	@set -e; for img in $(IMAGES); do $(MAKE) --no-print-directory test IMAGE=$$img; done

scan: require-image
	ci/sbom-scan.sh $(IMAGE)

list:
	@printf '%s\n' $(IMAGES)

require-image:
	@test -n "$(IMAGE)" || { echo "IMAGE fehlt, z. B. make build IMAGE=static (verfügbar: $(IMAGES))"; exit 1; }
	@test -d images/$(IMAGE) || { echo "images/$(IMAGE) gibt es nicht (verfügbar: $(IMAGES))"; exit 1; }
