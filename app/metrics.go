package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Prometheus metrics shared across modes (registered on the default registry).
var (
	tempGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "weather_temperature_celsius",
		Help: "Latest observed temperature in Celsius by city.",
	}, []string{"city"})

	windGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "weather_windspeed_kph",
		Help: "Latest observed windspeed in km/h by city.",
	}, []string{"city"})

	publishedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "weather_readings_published_total",
		Help: "Total readings published to the queue by the api.",
	})

	storedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "weather_readings_stored_total",
		Help: "Total readings written to Postgres by the store.",
	})
)
