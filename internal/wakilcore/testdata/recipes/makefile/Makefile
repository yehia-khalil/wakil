.PHONY: dev setup build
VERSION := 1
setup:
	go mod download
dev: setup
	go run .
build:
	go build -o bin/notify .
