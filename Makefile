NVIM ?= nvim

.PHONY: test live lint fmt

test:
	$(NVIM) --headless -u NONE -l tests/run.lua

live:
	$(NVIM) --headless -u NONE -l tests/live.lua

lint:
	stylua --check lua plugin tests

fmt:
	stylua lua plugin tests
