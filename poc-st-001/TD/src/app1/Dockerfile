FROM golang:latest as builder

LABEL maintainer="Hermann Wagner <hewagner@google.com>"

WORKDIR /app

COPY ./ ./

RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

FROM alpine:latest

WORKDIR /root/

COPY --from=builder /app/main .

EXPOSE 8000

ENTRYPOINT ./main
