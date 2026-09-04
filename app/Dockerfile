# ---- build stage: generate gRPC stubs + compile ----
FROM golang:1.26-alpine AS build
RUN apk add --no-cache protobuf protobuf-dev git
ENV GOBIN=/go/bin
ENV PATH="/go/bin:${PATH}"
WORKDIR /src

RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 \
 && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2

COPY go.mod ./
COPY proto ./proto
RUN protoc --go_out=. --go_opt=module=weather \
           --go-grpc_out=. --go-grpc_opt=module=weather \
           proto/weather.proto

COPY *.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 go build -trimpath -o /weather .

# ---- runtime stage ----
FROM alpine:3.24
RUN apk add --no-cache ca-certificates wget
COPY --from=build /weather /weather
ENTRYPOINT ["/weather"]
