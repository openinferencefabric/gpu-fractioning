# vram-probe: a small image for test/amd/quick-dmem-cap.sh (Ubuntu's ROCr runtime instead of a 20 GB PyTorch image)
#   docker build -t <repo>/oif-vram-probe:0.1 test/amd/vram-probe
FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev libhsa-runtime-dev && rm -rf /var/lib/apt/lists/*
COPY vram-probe.c /src/
RUN gcc -O2 -Wall -o /vram-probe /src/vram-probe.c -lhsa-runtime64

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libhsa-runtime64-1 && rm -rf /var/lib/apt/lists/*
COPY --from=build /vram-probe /usr/local/bin/vram-probe
ENTRYPOINT ["/usr/local/bin/vram-probe"]
