SUPER_LINTER_VERSION := $(shell grep -e '- uses: super-linter/super-linter@' .github/workflows/ci.yaml | cut -d'@' -f2)
DOCKER_ARGS = --rm --platform=linux/amd64 \
	--pull always \
	-e RUN_LOCAL=true \
	-e SHELL=/bin/bash \
	--env-file ".github/super-linter.env" \
	-v "$$PWD":/tmp/lint \
	ghcr.io/super-linter/super-linter:$(SUPER_LINTER_VERSION)

super-linter:
	docker run $(DOCKER_ARGS)

clq:
	docker run \
		--interactive --pull always --rm \
		--volume $$PWD/CHANGELOG.md:/home/CHANGELOG.md:ro \
		--volume $$PWD/.github/clq/changemap.json:/home/changemap.json:ro \
		denisa/clq:1.8.23 -changeMap /home/changemap.json /home/CHANGELOG.md

lint: clq super-linter

fix:
	docker run -e FIX=true $(DOCKER_ARGS)
