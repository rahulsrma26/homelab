SERVICES := $(shell find services -maxdepth 3 -name docker-compose.yml -exec dirname {} \; | sed 's|^services/||' | sort)

.PHONY: help labber test-labber-unit test-labber-vm test-monitoring $(SERVICES)

help:
	@echo "Usage: make <service|labber>"
	@echo ""
	@echo "Available services:"
	@for s in $(SERVICES); do echo "  $$s"; done

labber:
	git add labber && git commit -m "labber: update" && git push origin main

tool:
	git add tools && git commit -m "tools: update" && git push origin main

test:
	git add tests && git commit -m "tests: update" && git push origin main

# labber tests — see tests/labber/README.md
test-labber-unit:
	tests/labber/run-unit.sh

test-labber-vm:
	tests/labber/run-vm.sh $(if $(NETWORK),--network $(NETWORK))

# promtool checks for the Prometheus alert rules
test-monitoring:
	tests/monitoring/run.sh

$(SERVICES):
	git add services/$@ && git commit -m "$@: update" && git push origin main
