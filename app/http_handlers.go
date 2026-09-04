package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	pb "weather/genproto"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// apiServer bundles what the HTTP handlers below need. Grouping these two
// values here (instead of each handler being an anonymous closure that
// captures whatever variables happen to be in scope in serveHTTP) means
// every handler's dependencies are explicit and each one can be read - and
// tested - on its own.
type apiServer struct {
	store     pb.WeatherStoreClient // gRPC client to weather-store
	storeHTTP string                // e.g. "http://weather-store:9091"
}

// serveHTTP wires up every route and starts listening. This is the only
// exported entry point from this file - everything else here is a method
// on apiServer that some route below points to.
func serveHTTP(store pb.WeatherStoreClient, storeHTTP string) {
	s := &apiServer{store: store, storeHTTP: storeHTTP}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/readings/latest", s.handleReadingsLatest)
	mux.HandleFunc("/cities", s.handleCities)
	mux.HandleFunc("/", s.handleIndex)

	addr := ":" + getenv("API_PORT", "8080")
	log.Println("api: http on", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("api: http server: %v", err)
	}
}

// handleHealthz is what the Docker healthcheck in docker-compose.yml polls.
func (s *apiServer) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("ok"))
}

// handleIndex serves the single-page UI (search box + add-city form). The
// page itself is entirely static HTML/CSS/JS - see ui_page.go - it talks
// back to this server only through the JSON endpoints below.
func (s *apiServer) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(weatherUIHTML))
}

// --- GET /readings/latest ---------------------------------------------------

// handleReadingsLatest answers "what's the current weather", either for one
// city (?city=Paris) or for every tracked city (no query string - used by
// nothing right now except manual testing/curl, since the UI always asks
// for one city at a time).
func (s *apiServer) handleReadingsLatest(w http.ResponseWriter, r *http.Request) {
	names := s.cityNamesFromRequest(r)

	out := []reading{}
	for _, name := range names {
		if rd, found := s.getLatestFromStore(name); found {
			out = append(out, rd)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// cityNamesFromRequest decides which cities handleReadingsLatest should
// look up: just the one named in ?city=, or the entire tracked list.
func (s *apiServer) cityNamesFromRequest(r *http.Request) []string {
	if q := r.URL.Query().Get("city"); q != "" {
		return []string{q}
	}
	var names []string
	for _, c := range getCities() {
		names = append(names, c.Name)
	}
	return names
}

// getLatestFromStore asks weather-store (over gRPC) for the newest reading
// it has for one city. The bool return is "did we actually get a reading",
// not "did the call succeed" - a city with no data yet is not an error.
func (s *apiServer) getLatestFromStore(name string) (reading, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resp, err := s.store.GetLatest(ctx, &pb.GetLatestRequest{City: name})
	if err != nil {
		log.Printf("api: getLatest %s: %v", name, err)
		return reading{}, false
	}
	if !resp.Found || resp.Reading == nil {
		return reading{}, false
	}

	return reading{
		City:         resp.Reading.City,
		Latitude:     resp.Reading.Latitude,
		Longitude:    resp.Reading.Longitude,
		TemperatureC: resp.Reading.TemperatureC,
		WindspeedKph: resp.Reading.WindspeedKph,
		ObservedAt:   resp.Reading.ObservedAt,
		Source:       resp.Reading.Source,
	}, true
}

// --- GET/POST /cities --------------------------------------------------------

// handleCities just dispatches to the GET or POST version - kept tiny on
// purpose so the two very different jobs ("list what we have" vs. "resolve
// and add something new") don't end up tangled in one function.
func (s *apiServer) handleCities(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.handleCitiesGet(w, r)
	case http.MethodPost:
		s.handleCitiesPost(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handleCitiesGet returns the currently tracked cities - straight from the
// in-memory cache (city_cache.go), which is itself always sourced from the
// database, never from CITIES.
func (s *apiServer) handleCitiesGet(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(getCities())
}

// handleCitiesPost is the "+ Add city" flow from the UI. The request body
// is just {"name": "Paris"} - the user never supplies coordinates - so this
// is the one place that ties together geocoding, persisting, and getting
// an immediate first reading, in that order:
//
//  1. resolve the name to coordinates (geocodeCity)
//  2. persist it (addCityToStore -> store -> Postgres)
//  3. re-read the full list from the database, so the cache reflects
//     reality instead of being hand-patched with the one new entry
//  4. fetch and store a reading right away, so the user isn't staring at
//     "no data yet" until the next scheduled FETCH_INTERVAL cycle
//
// Step 4 failing (e.g. Open-Meteo hiccups) does not fail the request - the
// city is already saved by that point, and it'll just pick up a reading on
// the next regular cycle instead.
func (s *apiServer) handleCitiesPost(w http.ResponseWriter, r *http.Request) {
	name, err := decodeCityName(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	city, err := geocodeCity(name)
	if err != nil {
		http.Error(w, "could not resolve city: "+err.Error(), http.StatusBadRequest)
		return
	}

	if err := addCityToStore(s.storeHTTP, city); err != nil {
		http.Error(w, "could not save city: "+err.Error(), http.StatusBadGateway)
		return
	}

	s.refreshCitiesFromDB()
	s.fetchAndStoreNow(city)

	log.Printf("api: city added: %s (%.4f, %.4f)", city.Name, city.Lat, city.Lon)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(city)
}

// decodeCityName pulls {"name": "..."} out of the request body, rejecting
// anything blank or malformed before it ever reaches geocoding.
func decodeCityName(r *http.Request) (string, error) {
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		return "", errProvideCityName
	}
	name := strings.TrimSpace(body.Name)
	if name == "" {
		return "", errProvideCityName
	}
	return name, nil
}

var errProvideCityName = httpError("provide a city name")

// httpError is just a tiny named string type so decodeCityName's error can
// double as the exact text http.Error sends to the client - no separate
// "wrap it, then unwrap it for the message" step needed for a case this
// simple.
type httpError string

func (e httpError) Error() string { return string(e) }

// refreshCitiesFromDB re-reads the full city list from the database and
// replaces the cache with it. Called right after adding a city so the new
// one is visible immediately, instead of waiting for the periodic 30s
// refresh in runAPI (api.go).
func (s *apiServer) refreshCitiesFromDB() {
	if list, err := listCities(s.storeHTTP); err == nil {
		setCities(list)
	}
}

// fetchAndStoreNow fetches one city's current weather and writes it
// straight to the database via the same gRPC AddReading call the normal
// consumer pipeline uses - this is the "don't make them wait 5 minutes"
// shortcut described on handleCitiesPost above.
func (s *apiServer) fetchAndStoreNow(c cityCoord) {
	rd, err := fetchOne(c)
	if err != nil {
		log.Printf("api: immediate fetch for %s failed: %v", c.Name, err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = s.store.AddReading(ctx, &pb.Reading{
		City:         rd.City,
		Latitude:     rd.Latitude,
		Longitude:    rd.Longitude,
		TemperatureC: rd.TemperatureC,
		WindspeedKph: rd.WindspeedKph,
		ObservedAt:   rd.ObservedAt,
		Source:       rd.Source,
	})
	if err != nil {
		log.Printf("api: immediate reading store for %s: %v", c.Name, err)
		return
	}

	tempGauge.WithLabelValues(rd.City).Set(rd.TemperatureC)
	windGauge.WithLabelValues(rd.City).Set(rd.WindspeedKph)
	publishedTotal.Inc()
}
