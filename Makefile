.PHONY: deps test

# `helm dependency update` for the test chart (crdkit `file://` itself).
deps:
	cd tests/stub && helm dependency update

# Framework suites on tests/stub, text lint.
test: deps
	helm unittest tests/stub -f '../suites/*_test.yaml'
	scripts/lint.sh --regex-check-define crdkit.regexValid.internal --pending tests/lint.pending templates
