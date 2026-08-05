.PHONY: test
test:
	cd harness && helm dependency update
	helm unittest harness -f '../tests/*_test.yaml'
