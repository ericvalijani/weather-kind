package main

import (
	"fmt"
	"sync"
	"testing"
)

func TestGetSetCities(t *testing.T) {
	setCities(nil) // start from a known, empty state
	if got := getCities(); len(got) != 0 {
		t.Fatalf("expected empty cache, got %d cities", len(got))
	}

	want := []cityCoord{
		{Name: "Tehran", Lat: 35.6892, Lon: 51.3890},
		{Name: "Paris", Lat: 48.8566, Lon: 2.3522},
	}
	setCities(want)

	got := getCities()
	if len(got) != len(want) {
		t.Fatalf("expected %d cities, got %d", len(want), len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("city %d: expected %+v, got %+v", i, want[i], got[i])
		}
	}
}

// TestGetCitiesReturnsACopy is the whole reason getCities copies the
// slice before returning it: a caller mutating what it got back must
// never be able to corrupt the cache's own backing array.
func TestGetCitiesReturnsACopy(t *testing.T) {
	setCities([]cityCoord{{Name: "Tehran", Lat: 35.6892, Lon: 51.3890}})

	got := getCities()
	got[0].Name = "Corrupted"

	again := getCities()
	if again[0].Name != "Tehran" {
		t.Fatalf("cache was corrupted through a returned slice: got %q", again[0].Name)
	}
}

// TestConcurrentCityCacheAccess exercises the cache the way this app
// actually uses it: one path periodically replacing the whole list
// (refreshCityListPeriodically), many others reading it at the same time
// (every HTTP request). Run with `go test -race` to actually catch a
// broken mutex - without -race this test can pass even if the locking
// were wrong.
func TestConcurrentCityCacheAccess(t *testing.T) {
	var wg sync.WaitGroup

	for w := 0; w < 5; w++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				setCities([]cityCoord{
					{Name: fmt.Sprintf("writer-%d-city-%d", id, i), Lat: 1, Lon: 2},
				})
			}
		}(w)
	}

	for r := 0; r < 5; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				_ = getCities()
			}
		}()
	}

	wg.Wait()
}
