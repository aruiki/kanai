SHELL := /bin/bash
RUST_ENV := . "$$HOME/.cargo/env";
.PHONY: fmt check test build dev build-mozc run-model clean

fmt:
	$(RUST_ENV) cargo fmt --all

check:
	$(RUST_ENV) cargo fmt --all -- --check
	$(RUST_ENV) cargo clippy --workspace --all-targets -- -D warnings
	$(RUST_ENV) cargo test --workspace
	npm run build

test: check

build: check
	npm run build

dev:
	npm run dev

build-mozc:
	./scripts/build-mozc-bridge.sh

run-model:
	./scripts/run-local-model.sh

clean:
	rm -rf target dist coverage
