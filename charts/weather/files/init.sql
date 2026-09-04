CREATE TABLE IF NOT EXISTS weather_readings (
    id            BIGSERIAL PRIMARY KEY,
    city          TEXT NOT NULL,
    latitude      DOUBLE PRECISION,
    longitude     DOUBLE PRECISION,
    temperature_c DOUBLE PRECISION,
    windspeed_kph DOUBLE PRECISION,
    observed_at   TIMESTAMPTZ,
    source        TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weather_city_time
    ON weather_readings (city, observed_at DESC);

CREATE TABLE IF NOT EXISTS cities (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    latitude   DOUBLE PRECISION NOT NULL,
    longitude  DOUBLE PRECISION NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
