FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /relay .

FROM scratch
COPY --from=build /relay /relay
COPY web /web
USER 65534:65534
EXPOSE 8080
ENV RELAY_ADDR=:8080 RELAY_WEB=/web
ENTRYPOINT ["/relay"]
