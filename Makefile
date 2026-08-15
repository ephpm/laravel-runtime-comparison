.PHONY: smoke test bench charts

smoke:
	bash bench/smoke.sh

test:
	cd app && php artisan test

bench:
	bash bench/run.sh all

charts:
	@test -n "$(RUN_ID)" || (echo "Usage: make charts RUN_ID=<run-id>" && exit 1)
	python3 bench/generate-charts.py "$(RUN_ID)"
