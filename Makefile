.PHONY: deps docs test

# `helm dependency update` for the test chart (crdkit `file://` itself).
deps:
	cd tests/stub && helm dependency update

# Regenerates the define reference; `test` fails when the committed copy
# is stale.
docs:
	python3 -I scripts/extract.py reference . docs/defines.md

# Framework suites on tests/stub, text and extractor lint, docs freshness.
test: deps
	helm unittest tests/stub -f '../suites/*_test.yaml'
	scripts/lint.sh --regex-check-define crdkit.regexValid.internal --pending tests/lint.pending \
		--scopes public,internal --internal-suffix templates
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
		python3 -I scripts/extract.py reference . "$$tmp/defines.md"; \
		diff -u docs/defines.md "$$tmp/defines.md" || { \
			echo "make test: docs/defines.md does not match the templates — run make docs" >&2; exit 1; }
