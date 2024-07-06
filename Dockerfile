name: build-images

on:
  # Run every other morning, time chosen arbitrarily as a likely low-activity period.
  # This will ensure that the images are up to date with Hercules releases.
  schedule:
    - cron:  '45 11 * * */2'
  # Allow manual runs.
  workflow_dispatch:
  # Also run on updates to this repo.
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  build-hercules:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        HERCULES_SERVER_MODE: ["classic", "renewal"]
        HERCULES_PACKET_VERSION: ["20180418", "latest"]

    steps:
      - name: Check out repo
        uses: actions/checkout@v1

      - name: Set up QEMU for Docker
        uses: docker/setup-qemu-action@v1

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2

      - name: Login to GitHub Container Registry
        uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set image tags
        id: image_tags
        run: |
          # Mark classic image with packet version 20180418 as the default on "hercules" repo
          if [[ "${{ matrix.HERCULES_SERVER_MODE }}" == "classic" && "${{ matrix.HERCULES_PACKET_VERSION }}" == "20180418" ]]; then
            echo "tags=ghcr.io/lenaxia/docker-hercules/hercules-${{ matrix.HERCULES_SERVER_MODE }}-${{ matrix.HERCULES_PACKET_VERSION }}:latest,ghcr.io/lenaxia/docker-hercules/hercules:${{ matrix.HERCULES_SERVER_MODE }}-packetver-${{ matrix.HERCULES_PACKET_VERSION }},ghcr.io/lenaxia/docker-hercules/hercules:latest" >> $GITHUB_OUTPUT
          else
            echo "tags=ghcr.io/lenaxia/docker-hercules/hercules-${{ matrix.HERCULES_SERVER_MODE }}-${{ matrix.HERCULES_PACKET_VERSION }}:latest,ghcr.io/lenaxia/docker-hercules/hercules:${{ matrix.HERCULES_SERVER_MODE }}-packetver-${{ matrix.HERCULES_PACKET_VERSION }}" >> $GITHUB_OUTPUT
          fi

      - name: Build and publish armv6 image
        uses: docker/build-push-action@v2
        with:
          file: Dockerfile
          push: true
          tags: |
            ghcr.io/lenaxia/docker-hercules/hercules-${{ matrix.HERCULES_SERVER_MODE }}-${{ matrix.HERCULES_PACKET_VERSION }}:armv6
            ghcr.io/lenaxia/docker-hercules/hercules:${{ matrix.HERCULES_SERVER_MODE }}-packetver-${{ matrix.HERCULES_PACKET_VERSION }}-armv6
            ghcr.io/lenaxia/docker-hercules/hercules:armv6
          platforms: linux/arm/v6
          build-args: |
            HERCULES_SERVER_MODE=${{ matrix.HERCULES_SERVER_MODE }}
            HERCULES_PACKET_VERSION=${{ matrix.HERCULES_PACKET_VERSION }}

      - name: Build Hercules and publish images
        uses: docker/build-push-action@v2
        with:
          file: Dockerfile
          push: true
          tags: ${{ steps.image_tags.outputs.tags }}
          platforms: linux/amd64,linux/arm/v7,linux/arm64,linux/arm/v6
          build-args: |
            HERCULES_SERVER_MODE=${{ matrix.HERCULES_SERVER_MODE }}
            HERCULES_PACKET_VERSION=${{ matrix.HERCULES_PACKET_VERSION }}
