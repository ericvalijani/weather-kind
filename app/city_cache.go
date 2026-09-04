package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// cityCoord is a city name plus the coordinates Open-Meteo needs to fetch
// its weather. This is the one shared "city" shape used everywhere in the
// api binary - the cache below, the HTTP calls to store, and the JSON sent
// to the browser all use this same struct.
type cityCoord struct {
	Name string
	Lat  float64
	Lon  float64
}

// parseCities turns the CITIES env var format ("Name:lat:lon,Name:lat:lon")
// into a slice of cityCoord. Used exactly once, by store, to seed the
// database on the very first boot (see seedCities in store.go) - nothing
// in api.go should ever call this to build its working city list; that
// always comes from the database (see listCities below).
//
// Malformed entries (wrong number of ":"-separated parts) are silently
// skipped rather than crashing the whole app over one typo in .env.
func parseCities(s string) []cityCoord {
	var out []cityCoord
	for _, part := range strings.Split(s, ",") {
		fields := strings.Split(strings.TrimSpace(part), ":")
		if len(fields) != 3 {
			continue
		}
		lat, _ := strconv.ParseFloat(fields[1], 64)
		lon, _ := strconv.ParseFloat(fields[2], 64)
		out = append(out, cityCoord{Name: fields[0], Lat: lat, Lon: lon})
	}
	return out
}

// --- in-memory cache -------------------------------------------------------
//
// activeCities is api's own local copy of "which cities are we tracking."
// It exists purely so the fetch loop and the HTTP handlers don't have to
// make a network call to store every single time they need the list.
//
// The database (via store's /cities endpoint) is always the source of
// truth. This cache is refreshed from the database - at startup, every 30
// seconds, and immediately whenever a city is added through the UI - it is
// never the other way around. If you're tempted to update activeCities by
// hand (e.g. "just append the new city"), don't: re-read from the database
// instead, so the cache can never drift from what's actually stored.

var (
	citiesMu     sync.RWMutex
	activeCities []cityCoord
)

// getCities returns a snapshot of the current city list. It copies the
// slice before returning it so callers can't accidentally mutate the
// cache's backing array through the returned slice.
func getCities() []cityCoord {
	citiesMu.RLock()
	defer citiesMu.RUnlock()
	out := make([]cityCoord, len(activeCities))
	copy(out, activeCities)
	return out
}

// setCities replaces the cached list wholesale. Always call this with a
// list that just came from the database (listCities below) - never with a
// hand-edited copy of the old list.
func setCities(cities []cityCoord) {
	citiesMu.Lock()
	activeCities = cities
	citiesMu.Unlock()
}

// --- talking to store's /cities endpoint ------------------------------------
//
// store owns the `cities` table in Postgres and is the only thing allowed
// to touch it directly (same rule as weather_readings). api reaches it
// through store's small REST surface on :9091, not gRPC - these two
// functions are the entire interface.

// listCities reads the full, current city list straight from the database.
// This is the only way api's cache ever learns about a city - whether it
// was added through this app's own UI or inserted directly with psql.
func listCities(storeHTTP string) ([]cityCoord, error) {
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(storeHTTP + "/cities")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("store /cities: status %d", resp.StatusCode)
	}
	var cities []cityCoord
	if err := json.NewDecoder(resp.Body).Decode(&cities); err != nil {
		return nil, err
	}
	return cities, nil
}

// addCityToStore asks store to persist a new city (name + coordinates
// already resolved by geocodeCity). store does the actual
// INSERT ... ON CONFLICT DO UPDATE - this function just makes the HTTP call
// and turns a non-200 response into a Go error.
func addCityToStore(storeHTTP string, c cityCoord) error {
	body, _ := json.Marshal(c)
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post(storeHTTP+"/cities", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("store /cities: status %d: %s", resp.StatusCode, strings.TrimSpace(string(errBody)))
	}
	return nil
}
