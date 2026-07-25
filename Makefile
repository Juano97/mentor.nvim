NVIM ?= nvim
SPECS := $(sort $(wildcard tests/*_spec.lua))

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'

.PHONY: test
test: ## Run the offline suite (network specs self-skip)
	@fail=0; \
	for spec in $(SPECS); do \
		echo "$$spec"; \
		MENTOR_SPEC="$$spec" $(NVIM) --headless -u tests/minimal_init.lua || fail=1; \
	done; \
	echo; \
	if [ $$fail -ne 0 ]; then echo "FAILED"; exit 1; else echo "all specs passed"; fi

.PHONY: test-e2e
test-e2e: ## Run the live spec too (spends real quota via the claude CLI)
	@MENTOR_E2E=1 $(MAKE) test

.PHONY: test-one
test-one: ## Run a single spec: make test-one SPEC=tests/ui_spec.lua
	@test -n "$(SPEC)" || { echo "usage: make test-one SPEC=tests/ui_spec.lua"; exit 2; }
	@MENTOR_SPEC="$(SPEC)" $(NVIM) --headless -u tests/minimal_init.lua
