ISO :=
IMG ?= lunar-linux
TAG ?= latest
EXT ?=
SUF ?=
PWD = $(shell pwd)

all: dockerize

dockerize:
	@if ! test -f $(ISO); then echo "ISO= not set to a valid ISO file"; exit 1; fi
	$(PWD)/dockerize-lunar.sh -i "$(ISO)" -n "$(IMG)" -t "$(TAG)" -e "$(EXT)" -s "$(SUF)"

ci-docker: dockerize
	@echo "Building $@"
	docker build -t lunar-linux:latest --rm .

.PHONY: all dockerize ci-docker
