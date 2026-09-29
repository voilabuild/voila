# syntax=docker/dockerfile:1

# Build stage: compile the voila-registry binary with the same pure-Go,
# CGO-disabled settings used by the Makefile and release pipeline.
FROM golang:1.26 AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /bin/voila-registry ./cmd/voila-registry

# Runtime stage: minimal Alpine image with a writable /data directory.
# The registry is stateful (chunks + image manifests are persisted on disk),
# so /data is created here and owned by the non-root user the container runs as.
FROM alpine:latest

RUN apk add --no-cache ca-certificates && \
    mkdir -p /data && \
    chown -R 65532:65532 /data

COPY --from=builder --chown=65532:65532 /bin/voila-registry /voila-registry

USER 65532
ENV VOILA_ROOT=/data
EXPOSE 7423

ENTRYPOINT ["/voila-registry"]
