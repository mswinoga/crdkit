.PHONY: deps docs test

# `helm dependency update` for the test chart (crdkit `file://` itself).
deps:
	cd tests/stub && helm dependency update

# Regenerates the define reference, the diagnostics list, the README
# example blocks and its toc; `test` fails when a committed copy is stale.
docs: deps
	python3 -I scripts/extract.py reference . docs/defines.md
	python3 -I scripts/extract.py diagnostics . docs/diagnostics.md
	python3 -I scripts/examples.py render README.md --chart tests/stub --kind stub
	python3 -I scripts/toc.py render README.md

# Framework suites on tests/stub, text and extractor lint, docs freshness.
test: deps
	helm unittest tests/stub -f '../suites/*_test.yaml'
	scripts/lint.sh --regex-check-define crdkit.regexValid.internal --pending tests/lint.pending \
		--scopes public,internal --internal-suffix --doc-rules --md README.md --md CONTRIBUTING.md \
		--md docs/requirements.md --requirements docs/requirements.md --tests tests --readme README.md \
		templates
	python3 -I scripts/examples.py check README.md --chart tests/stub --kind stub
	python3 -I scripts/toc.py check README.md
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
		python3 -I scripts/extract.py reference . "$$tmp/defines.md"; \
		python3 -I scripts/extract.py diagnostics . "$$tmp/diagnostics.md"; \
		for f in defines.md diagnostics.md; do \
			diff -u "docs/$$f" "$$tmp/$$f" || { \
				echo "make test: docs/$$f does not match the templates — run make docs" >&2; exit 1; }; \
		done
