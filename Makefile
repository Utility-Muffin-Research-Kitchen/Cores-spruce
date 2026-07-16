SHELL := /bin/bash

.PHONY: check check-report check-probe

check: check-report check-probe
	@bash -n build-mlp1.sh probe-mlp1-cores-adb.sh \
		scripts/stage-mlp1-probe-libs.sh

check-report:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v

check-probe:
	@tmp="$$(mktemp "$${TMPDIR:-/tmp}/mlp1-core-info-probe.XXXXXX")"; \
	trap 'rm -f "$$tmp"' EXIT; \
	dl_flag="-ldl"; \
	if [[ "$$(uname -s)" == "Darwin" ]]; then dl_flag=""; fi; \
	$${CC:-cc} -std=c11 -Wall -Wextra -Werror \
		tools/mlp1-core-info-probe.c $$dl_flag -o "$$tmp"
