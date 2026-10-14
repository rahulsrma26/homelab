SERVICES := $(shell find services -maxdepth 3 -name docker-compose.yml -exec dirname {} \; | sed 's|^services/||' | sort)

.PHONY: hooks help labber test-labber-unit test-labber-setup test-labber-vm test-monitoring test-scripts test-lint ci $(SERVICES)

help:
	@echo "Usage: make <service|labber>"
	@echo ""
	@echo "Available services:"
	@for s in $(SERVICES); do echo "  $$s"; done

# push to dev; CI fast-forwards main (what machines install from) once every test passes
# turn on the repo's git hooks (.githooks/pre-push: no personal details, IPs, keys, .env)
hooks:
	git config core.hooksPath .githooks
	@echo "hooks on: every push runs the repo lint (personal/lint-denylist.txt for your own words)"

add:
	git add services && git add labber && git add tools && git add tests && git add README.md && git commit -m "all update" && git push origin dev

script:
	git add scripts && git commit -m "scripts: update" && git push origin dev

service:
	git add services && git commit -m "services: update" && git push origin dev

labber:
	git add labber && git commit -m "labber: update" && git push origin dev

tool:
	git add tools && git commit -m "tools: update" && git push origin dev

test:
	git add tests && git commit -m "tests: update" && git push origin dev

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

# scripts/ end-to-end in systemd containers: NUT (simulated UPS) and smbmgr (Samba)
test-scripts:
	tests/scripts/run-nut.sh
	tests/scripts/run-smbmgr.sh

# repo rules (CLAUDE.md) + shellcheck — what CI runs besides the tests above
test-lint:
	tests/repo/run.sh
	tests/repo/shellcheck.sh

# everything CI runs
ci: test-lint test-labber-unit test-labber-setup test-monitoring test-scripts

$(SERVICES):
	git add services/$@ && git commit -m "$@: update" && git push origin dev
