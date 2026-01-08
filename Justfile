default: format test build run

up: build run

check: format test build

build:
  zig build

format:
  zig fmt src

run:
  ./zig-out/bin/cardigan

# Test targets
test-unit flags="":
  zig build test-unit {{flags}}

test-integration flags="":
  zig build test-integration {{flags}}

test-system flags="":
  zig build test-system {{flags}}

test: test-unit test-integration test-system

test-verbose: (test-unit "--summary all") (test-integration "--summary all") (test-system "summary-all")

