package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// storeHTTPServer is store's small REST surface - separate from the gRPC
// service in store.go. Three routes, all on :9091:
//
//	/healthz  - polled by the Docker healthcheck in docker-compose.yml
//	/metrics  - scraped by Prometheus
//	/cities   - the only place in this whole project that runs SQL
//	            against the `cities` table (api reaches it over plain
//	            HTTP, not gRPC, since it's simple key-value-ish data with
//	            no need for a typed contract)
type storeHTTPServer struct {
	db *sql.DB
}

// serveStoreHTTP wires up the three routes and listens forever. Meant to
// be started with `go serveStoreHTTP(db)` from runStore, alongside the
// gRPC server.
func serveStoreHTTP(db *sql.DB) {
	s := &storeHTTPServer{db: db}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/cities", s.handleCities)

	log.Println("store: health+metrics on :9091")
	if err := http.ListenAndServe(":9091", mux); err != nil {
		log.Printf("store: health server: %v", err)
	}
}

func (s *storeHTTPServer) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

// handleCities dispatches to the GET or POST version - same "keep it tiny"
// reasoning as apiServer.handleCities in http_handlers.go.
func (s *storeHTTPServer) handleCities(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.handleCitiesGet(w, r)
	case http.MethodPost:
		s.handleCitiesPost(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handleCitiesGet returns every row in the cities table, alphabetically.
// This is what api's listCities (city_cache.go) calls to refresh its cache.
func (s *storeHTTPServer) handleCitiesGet(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`SELECT name, latitude, longitude FROM cities ORDER BY name`)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	out := []cityCoord{}
	for rows.Next() {
		var c cityCoord
		if err := rows.Scan(&c.Name, &c.Lat, &c.Lon); err == nil {
			out = append(out, c)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// handleCitiesPost inserts a new city, or updates its coordinates if the
// name already exists (ON CONFLICT ... DO UPDATE) - so re-adding "Paris"
// twice is harmless, it just refreshes the stored coordinates rather than
// erroring. The caller (api's addCityToStore) is expected to have already
// resolved the name to coordinates via geocoding before this is ever
// called - this endpoint trusts the coordinates it's given.
func (s *storeHTTPServer) handleCitiesPost(w http.ResponseWriter, r *http.Request) {
	var c cityCoord
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil || c.Name == "" {
		http.Error(w, "invalid city payload", http.StatusBadRequest)
		return
	}

	_, err := s.db.Exec(
		`INSERT INTO cities (name, latitude, longitude) VALUES ($1,$2,$3)
		 ON CONFLICT (name) DO UPDATE SET latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude`,
		c.Name, c.Lat, c.Lon)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("store: city added/updated: %s (%.4f, %.4f)", c.Name, c.Lat, c.Lon)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(c)
}
