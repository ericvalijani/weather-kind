package main

import (
	"log"
	"os"
	"time"
)

// getenv returns the env var or a default when unset/empty.
func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// mustDuration parses a duration env var (e.g. "300s") or dies.
func mustDuration(key, def string) time.Duration {
	d, err := time.ParseDuration(getenv(key, def))
	if err != nil {
		log.Fatalf("invalid duration for %s: %v", key, err)
	}
	return d
}

// One binary, three roles selected by MODE.
func main() {
	switch getenv("MODE", "") {
	case "store":
		runStore()
	case "api":
		runAPI()
	case "consumer":
		runConsumer()
	default:
		log.Fatal("set MODE=store|api|consumer")
	}
}
