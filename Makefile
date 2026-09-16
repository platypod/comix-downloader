IMAGE    := ghcr.io/platypod/comix-downloader
VERSION  ?= v0.1.0
# Upstream commit this image wraps. Bump deliberately: the Dockerfile's patches
# assert on exact upstream lines and the build FAILS LOUDLY if they moved.
COMIX_REF ?= 97a63fa55bbf0813b84ebca60e2f2c5361755bbd
BUILDER  := platypod-multiarch

.PHONY: builder build

builder:  ## Create the multi-arch buildx builder (once per machine)
	docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
	  docker buildx create --name $(BUILDER) --driver docker-container --bootstrap
	docker buildx use $(BUILDER)

build: builder  ## Build multi-arch image (linux/amd64 + linux/arm64) and push to GHCR
	docker buildx build \
	  --platform linux/amd64,linux/arm64 \
	  --build-arg COMIX_REF=$(COMIX_REF) \
	  -t $(IMAGE):$(VERSION) \
	  -t $(IMAGE):latest \
	  --push \
	  .

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
