.PHONY: deps test

# `helm dependency update` per chart that depends on crdkit (file://).
deps:
	cd harness && helm dependency update
	cd tests/stub && helm dependency update

# Legacy suites on harness/, framework suites on tests/stub, text lint.
test: deps
	helm unittest harness -f '../tests/*_test.yaml'
	helm unittest tests/stub -f '../suites/*_test.yaml'
	scripts/lint.sh --pending tests/lint.pending templates
