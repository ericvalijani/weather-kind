package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDecodeCityName(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		want    string
		wantErr bool
	}{
		{name: "valid name", body: `{"name":"Paris"}`, want: "Paris"},
		{name: "trims whitespace", body: `{"name":"  Tokyo  "}`, want: "Tokyo"},
		{name: "empty name", body: `{"name":""}`, wantErr: true},
		{name: "whitespace-only name", body: `{"name":"   "}`, wantErr: true},
		{name: "missing name field", body: `{}`, wantErr: true},
		{name: "malformed JSON", body: `{not json`, wantErr: true},
		{name: "empty body", body: ``, wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/cities", strings.NewReader(tc.body))
			got, err := decodeCityName(req)

			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got name %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("expected %q, got %q", tc.want, got)
			}
		})
	}
}

// TestErrProvideCityNameMessage pins the exact error text, since
// decodeCityName's error doubles as what http.Error sends straight to the
// client (see handleCitiesPost) - a future edit changing this message
// without meaning to would otherwise go unnoticed.
func TestErrProvideCityNameMessage(t *testing.T) {
	if errProvideCityName.Error() != "provide a city name" {
		t.Fatalf("unexpected error message: %q", errProvideCityName.Error())
	}
}
