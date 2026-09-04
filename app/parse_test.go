package main

import "testing"

func TestParseCities(t *testing.T) {
	got := parseCities("Tehran:35.6892:51.3890,Berlin:52.52:13.405")
	if len(got) != 2 {
		t.Fatalf("expected 2 cities, got %d", len(got))
	}
	if got[0].Name != "Tehran" {
		t.Errorf("expected first city Tehran, got %q", got[0].Name)
	}
	if got[1].Lat != 52.52 {
		t.Errorf("expected Berlin lat 52.52, got %v", got[1].Lat)
	}
}

func TestParseCitiesSkipsMalformed(t *testing.T) {
	got := parseCities("Bad,Tokyo:35.6762:139.6503,")
	if len(got) != 1 {
		t.Fatalf("expected 1 valid city, got %d", len(got))
	}
	if got[0].Name != "Tokyo" {
		t.Errorf("expected Tokyo, got %q", got[0].Name)
	}
}
