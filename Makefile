SERVICES := $(shell find services -maxdepth 3 -name docker-compose.yml -exec dirname {} \; | sed 's|^services/||' | sort)

.PHONY: help labber $(SERVICES)

help:
	@echo "Usage: make <service|labber>"
	@echo ""
	@echo "Available services:"
	@for s in $(SERVICES); do echo "  $$s"; done

labber:
	git add services/labber && git commit -m "labber: update" && git push origin main

$(SERVICES):
	git add services/$@ && git commit -m "$@: update" && git push origin main
