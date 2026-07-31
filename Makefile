SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.RECIPEPREFIX := >

.PHONY: doctor create redfish destroy test test-integration clean

doctor:
>./scripts/doctor

create:
>./scripts/create-vm

redfish:
>./scripts/run-redfish

destroy:
>./scripts/destroy-vm

OFFLINE_BATS_TESTS := $(wildcard tests/command-surface.bats tests/doctor.bats)
OFFLINE_BATS_TESTS += $(wildcard tests/render-config.bats tests/create-vm.bats)
OFFLINE_BATS_TESTS += $(wildcard tests/destroy-vm.bats)
SHELL_SCRIPTS := $(wildcard scripts/doctor scripts/create-vm scripts/destroy-vm)
SHELL_SCRIPTS += $(wildcard scripts/render-config scripts/run-redfish scripts/lib/common)
SHELLCHECK_FILES := $(SHELL_SCRIPTS) $(wildcard tests/helpers/test-helper.bash)
EXECUTABLE_SCRIPTS := $(filter-out scripts/lib/common,$(SHELL_SCRIPTS))
PYTHON_313 := $(shell UV_PYTHON_DOWNLOADS=never uv python find 3.13 2>/dev/null)
PYTHON_FILES := $(wildcard tests/helpers/*.py)
SHFMT_PATHS := $(wildcard scripts tests)

test:
>@if [ -n "$(OFFLINE_BATS_TESTS)" ]; then bats $(OFFLINE_BATS_TESTS); fi
>@if [ -n "$(strip $(SHELLCHECK_FILES))" ]; then shellcheck -x $(SHELLCHECK_FILES); fi
>@for script in $(EXECUTABLE_SCRIPTS); do test -x "$$script"; done
>@if [ -n "$(SHFMT_PATHS)" ]; then shfmt -i 2 -d $(SHFMT_PATHS); fi
>@if [ -n "$(PYTHON_FILES)" ]; then \
>  uv run --locked --only-group dev --no-install-project ruff check $(PYTHON_FILES); \
>fi
>@if [ -n "$(PYTHON_FILES)" ]; then \
>  uv run --locked --only-group dev --no-install-project ruff format --check $(PYTHON_FILES); \
>fi
>@if [ -n "$(PYTHON_FILES)" ]; then \
>  uv run --locked --only-group dev --no-install-project ty check $(PYTHON_FILES); \
>fi
>@if [ -f uv.lock ]; then uv lock --check; fi
>@if [ -f config/sushy-emulator.conf.py.in ]; then \
>  test -n "$(PYTHON_313)"; \
>  "$(PYTHON_313)" -m py_compile config/sushy-emulator.conf.py.in; \
>fi

test-integration:
>bats tests/redfish-integration.bats

clean:
>./scripts/destroy-vm
