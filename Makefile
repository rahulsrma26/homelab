SERVICES := $(shell find services -maxdepth 3 -name docker-compose.yml -exec dirname {} \; | sed 's|^services/||' | sort)

.PHONY: help labber test-labber-unit test-labber-setup test-labber-vm test-monitoring test-lint ci $(SERVICES)

help:
	@echo "Usage: make <service|labber>"
	@echo ""
	@echo "Available services:"
	@for s in $(SERVICES); do echo "  $$s"; done

add:
	git add services && git add labber && git add tools && git add tests && git add README.md && git commit -m "all update" && git push origin main

service:
	git add services && git commit -m "services: update" && git push origin main

labber:
	git add labber && git commit -m "labber: update" && git push origin main

tool:
	git add tools && git commit -m "tools: update" && git push origin main

test:
	git add tests && git commit -m "tests: update" && git push origin main

# labber tests — see tests/labber/README.md
test-labber-unit:
	tests/labber/run-unit.sh

test-labber-setup:
	tests/labber/run-setup.sh

test-labber-vm:
	tests/labber/run-vm.sh $(if $(NETWORK),--network $(NETWORK))

# promtool checks for the Prometheus alert rules
test-monitoring:
	tests/monitoring/run.sh

# repo rules (CLAUDE.md) + shellcheck — what CI runs besides the tests above
test-lint:
	tests/repo/run.sh
	tests/repo/shellcheck.sh

# everything CI runs
ci: test-lint test-labber-unit test-labber-setup test-monitoring

$(SERVICES):
	git add services/$@ && git commit -m "$@: update" && git push origin main
