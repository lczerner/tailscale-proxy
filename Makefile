IMAGE := localhost/tailscale-proxy
LISTEN_PORT := 8080

.PHONY: build run

build:
	podman build --format docker -t $(IMAGE) .

rebuild:
	podman build --format docker --no-cache -t $(IMAGE) .

run:
	@test -f .env || (echo "ERROR: .env file not found"; exit 1)
	podman run --env-file ./.env --rm -it \
		-p $(LISTEN_PORT):$(LISTEN_PORT) \
		-v ./tailscale-data/:/var/lib/tailscale \
		$(IMAGE)
