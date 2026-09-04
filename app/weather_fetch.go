package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// reading is one weather observation for one city. This is what gets
// published to RabbitMQ, what store persists to Postgres, and what
// /readings/latest returns to the browser - the JSON tags below are the
// public API shape, so change them with care.
type reading struct {
	City         string  `json:"city"`
	Latitude     float64 `json:"latitude"`
	Longitude    float64 `json:"longitude"`
	TemperatureC float64 `json:"temperature_c"`
	WindspeedKph float64 `json:"windspeed_kph"`
	ObservedAt   string  `json:"observed_at"`
	Source       string  `json:"source"`
}

// geocodeCity turns a plain city name (whatever the user typed in the
// search box) into coordinates, using Open-Meteo's free geocoding API - no
// account or API key needed. It returns only the single best match; if the
// name is ambiguous ("Springfield") this just picks whichever result the
// API ranks first rather than asking the user to disambiguate.
func geocodeCity(name string) (cityCoord, error) {
	endpoint := "https://geocoding-api.open-meteo.com/v1/search?count=1&name=" + url.QueryEscape(name)
	client := http.Client{Timeout: 10 * time.Second}

	resp, err := client.Get(endpoint)
	if err != nil {
		return cityCoord{}, err
	}
	defer resp.Body.Close()

	var parsed struct {
		Results []struct {
			Name      string  `json:"name"`
			Latitude  float64 `json:"latitude"`
			Longitude float64 `json:"longitude"`
			Country   string  `json:"country"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return cityCoord{}, err
	}
	if len(parsed.Results) == 0 {
		return cityCoord{}, fmt.Errorf("no match found for %q", name)
	}

	first := parsed.Results[0]
	return cityCoord{Name: first.Name, Lat: first.Latitude, Lon: first.Longitude}, nil
}

// fetchOne calls Open-Meteo's forecast API for a single city and returns
// its current conditions. This is the one function that actually knows the
// shape of Open-Meteo's forecast response - everywhere else in this
// codebase deals with the simpler `reading` struct instead.
func fetchOne(c cityCoord) (reading, error) {
	endpoint := fmt.Sprintf(
		"https://api.open-meteo.com/v1/forecast?latitude=%f&longitude=%f&current_weather=true",
		c.Lat, c.Lon)

	client := http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(endpoint)
	if err != nil {
		return reading{}, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var parsed struct {
		CurrentWeather struct {
			Temperature float64 `json:"temperature"`
			Windspeed   float64 `json:"windspeed"`
			Time        string  `json:"time"`
		} `json:"current_weather"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return reading{}, err
	}

	return reading{
		City:         c.Name,
		Latitude:     c.Lat,
		Longitude:    c.Lon,
		TemperatureC: parsed.CurrentWeather.Temperature,
		WindspeedKph: parsed.CurrentWeather.Windspeed,
		ObservedAt:   parsed.CurrentWeather.Time,
		Source:       "open-meteo",
	}, nil
}

// publishAll is the regular fetch cycle: for every city currently being
// tracked, fetch its weather from Open-Meteo and publish it onto the
// RabbitMQ queue for weather-consumer to pick up and store. One failed
// city (a bad network blip, Open-Meteo briefly down) just gets logged and
// skipped - it doesn't abort the whole cycle for every other city.
//
// A fresh AMQP connection is opened on every call rather than kept open
// between cycles - simple, and fine at the default 5-minute interval. Worth
// revisiting (a persistent connection) if FETCH_INTERVAL is ever set much
// shorter than that.
func publishAll(amqpURL, queue string, cities []cityCoord) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		log.Printf("api: amqp dial: %v", err)
		return
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		log.Printf("api: channel: %v", err)
		return
	}
	defer ch.Close()

	if _, err := ch.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		log.Printf("api: queue declare: %v", err)
		return
	}

	for _, c := range cities {
		rd, err := fetchOne(c)
		if err != nil {
			log.Printf("api: fetch %s: %v", c.Name, err)
			continue
		}

		body, _ := json.Marshal(rd)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err = ch.PublishWithContext(ctx, "", queue, false, false, amqp.Publishing{
			ContentType: "application/json",
			Body:        body,
		})
		cancel()
		if err != nil {
			log.Printf("api: publish %s: %v", c.Name, err)
			continue
		}

		tempGauge.WithLabelValues(rd.City).Set(rd.TemperatureC)
		windGauge.WithLabelValues(rd.City).Set(rd.WindspeedKph)
		publishedTotal.Inc()
		log.Printf("api: published %s temp=%.1f", rd.City, rd.TemperatureC)
	}
}
