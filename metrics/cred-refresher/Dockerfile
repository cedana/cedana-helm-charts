# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod ./

# Download dependencies (none for this simple app)
RUN go mod download

# Copy source
COPY main.go ./

# Build static binary
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o cred-refresher .

# Runtime stage - use distroless for minimal image
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /app/cred-refresher /cred-refresher

USER nonroot:nonroot

ENTRYPOINT ["/cred-refresher"]
