package main

import (
	"fmt"
	"log"
	"time"

	pb "weather/genproto"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// apiConfig is every environment-derived setting runAPI needs, gathered in
// one place so the rest of this file reads configuration once, up front,
// instead of calling getenv() scattered throughout.
type apiConfig struct {
	amqpURL   string
	queue     string
	interval  time.Duration
	storeAddr string // gRPC address, e.g. "weather-store:9090"
	storeHTTP string // REST base URL, e.g. "http://weather-store:9091"
}

func loadAPIConfig() apiConfig {
	return apiConfig{
		amqpURL: fmt.Sprintf("amqp://%s:%s@%s:%s/",
			getenv("RABBITMQ_DEFAULT_USER", "admin"),
			getenv("RABBITMQ_DEFAULT_PASS", ""),
			getenv("AMQP_HOST", "rabbitmq"),
			getenv("AMQP_PORT", "5672")),
		queue:     getenv("QUEUE", "weather.readings"),
		interval:  mustDuration("FETCH_INTERVAL", "300s"),
		storeAddr: getenv("STORE_ADDR", "weather-store:9090"),
		storeHTTP: getenv("STORE_HTTP_ADDR", "http://weather-store:9091"),
	}
}

// runAPI is the entire life of the `api` mode, top to bottom: load config,
// connect to store, make sure we know the current city list, then start
// the two things that run forever - the HTTP server and the fetch loop.
//
// Each step below is its own small function purely so this one reads like
// a table of contents. If you want the details of any one step, go to that
// function - you shouldn't need to read this whole thing to understand any
// single part of it.
func runAPI() {
	cfg := loadAPIConfig()

	conn := mustDialStore(cfg.storeAddr)
	defer conn.Close()
	store := pb.NewWeatherStoreClient(conn)

	waitForInitialCityList(cfg.storeHTTP)
	go refreshCityListPeriodically(cfg.storeHTTP)
	go serveHTTP(store, cfg.storeHTTP)

	runFetchLoop(cfg)
}

// mustDialStore opens the gRPC connection to weather-store. "must" because
// there's nothing sensible to do if this fails at startup - api can't work
// at all without a store client, so we fail loudly and let Docker's
// restart policy try again.
func mustDialStore(addr string) *grpc.ClientConn {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("api: cannot create store client: %v", err)
	}
	return conn
}

// waitForInitialCityList blocks until store answers with a real city list,
// so the very first fetch cycle has actual cities to work with instead of
// an empty one. Retries because store itself might still be starting -
// Docker starts containers in parallel, it doesn't wait for dependencies
// to be fully ready by default.
func waitForInitialCityList(storeHTTP string) {
	const attempts = 30
	const delay = 2 * time.Second

	for i := 0; i < attempts; i++ {
		if list, err := listCities(storeHTTP); err == nil {
			setCities(list)
			return
		}
		time.Sleep(delay)
	}
	log.Printf("api: could not reach store for initial city list after %d attempts, starting with an empty list", attempts)
}

// refreshCityListPeriodically keeps the in-memory cache in sync with
// Postgres for as long as the process runs. This is what makes a city
// added directly in the database (outside this app's own UI) eventually
// show up here too, without a restart. Intended to run in its own
// goroutine (`go refreshCityListPeriodically(...)`) - it never returns.
func refreshCityListPeriodically(storeHTTP string) {
	const interval = 30 * time.Second
	for {
		time.Sleep(interval)
		if list, err := listCities(storeHTTP); err == nil {
			setCities(list)
		}
	}
}

// runFetchLoop is the heartbeat of the whole app: every FETCH_INTERVAL,
// fetch and publish weather for whatever cities are currently tracked.
// Never returns - this is meant to be the last thing runAPI calls.
func runFetchLoop(cfg apiConfig) {
	log.Printf("api: fetch loop every %s", cfg.interval)
	for {
		publishAll(cfg.amqpURL, cfg.queue, getCities())
		time.Sleep(cfg.interval)
	}
}
