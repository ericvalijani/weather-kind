package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net"
	"time"

	pb "weather/genproto"

	_ "github.com/lib/pq"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
)

// storeServer implements the WeatherStore gRPC service (AddReading,
// GetLatest below). This is the only thing in the whole project that
// talks to Postgres and Redis directly for weather readings - api and
// consumer only ever reach that data through this gRPC interface. (The
// `cities` table is a separate, simpler case - see store_http.go.)
type storeServer struct {
	pb.UnimplementedWeatherStoreServer
	db  *sql.DB
	rdb *redis.Client
	ttl time.Duration
}

// runStore is the entire life of the `store` mode: connect to Postgres,
// connect to Redis, seed the cities table on first boot, then start both
// servers - the REST one (store_http.go) in the background, the gRPC one
// in the foreground.
func runStore() {
	db := mustConnectPostgres()

	rdb := redis.NewClient(&redis.Options{Addr: getenv("REDIS_ADDR", "redis:6379")})
	srv := &storeServer{db: db, rdb: rdb, ttl: mustDuration("CACHE_TTL", "120s")}
	seedCities(db, getenv("CITIES", ""))

	go serveStoreHTTP(db)

	serveGRPC(srv)
}

// mustConnectPostgres retries the connection up to 30 times, 2 seconds
// apart, before giving up. This matters because Docker Compose starts
// containers in parallel by default - by the time this process starts,
// the postgres container may exist but Postgres itself might not have
// finished initializing yet. "must" because there's nothing useful this
// service can do without a database.
func mustConnectPostgres() *sql.DB {
	dsn := "host=" + getenv("PGHOST", "postgres") +
		" port=" + getenv("PGPORT", "5432") +
		" user=" + getenv("POSTGRES_USER", "weather") +
		" password=" + getenv("POSTGRES_PASSWORD", "") +
		" dbname=" + getenv("POSTGRES_DB", "weatherdb") +
		" sslmode=disable"

	const attempts = 30
	const delay = 2 * time.Second

	var db *sql.DB
	var err error
	for i := 0; i < attempts; i++ {
		db, err = sql.Open("postgres", dsn)
		if err == nil {
			err = db.Ping()
		}
		if err == nil {
			log.Println("store: connected to postgres")
			return db
		}
		log.Printf("store: waiting for postgres: %v", err)
		time.Sleep(delay)
	}
	log.Fatalf("store: cannot connect to postgres: %v", err)
	return nil // unreachable - log.Fatalf exits the process
}

// serveGRPC starts the WeatherStore gRPC server and blocks forever (or
// until it fails). Meant to be the last thing runStore calls.
func serveGRPC(srv *storeServer) {
	lis, err := net.Listen("tcp", ":9090")
	if err != nil {
		log.Fatalf("store: listen: %v", err)
	}
	g := grpc.NewServer()
	pb.RegisterWeatherStoreServer(g, srv)
	log.Println("store: gRPC on :9090")
	if err := g.Serve(lis); err != nil {
		log.Fatalf("store: serve: %v", err)
	}
}

// AddReading is the write path: insert into Postgres (the permanent
// record), then best-effort refresh the Redis cache. If the cache write
// fails, that's not treated as an error - GetLatest below will just fall
// back to Postgres on its next call, so a Redis hiccup here never loses
// the actual reading.
func (s *storeServer) AddReading(ctx context.Context, r *pb.Reading) (*pb.AddReadingResponse, error) {
	var id int64
	err := s.db.QueryRowContext(ctx,
		`INSERT INTO weather_readings
		 (city, latitude, longitude, temperature_c, windspeed_kph, observed_at, source)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		r.City, r.Latitude, r.Longitude, r.TemperatureC, r.WindspeedKph, r.ObservedAt, r.Source,
	).Scan(&id)
	if err != nil {
		return nil, err
	}

	if b, e := json.Marshal(r); e == nil {
		s.rdb.Set(ctx, "latest:"+r.City, b, s.ttl)
	}

	storedTotal.Inc()
	log.Printf("store: saved id=%d city=%s temp=%.1f", id, r.City, r.TemperatureC)
	return &pb.AddReadingResponse{Id: id}, nil
}

// GetLatest is the read path: Redis first (the fast, common case), and
// only fall back to Postgres on a cache miss. A miss happens either
// because CACHE_TTL expired naturally, or because Redis was restarted and
// lost its data - Postgres being the permanent record means neither case
// ever actually loses a reading, just costs one extra query.
func (s *storeServer) GetLatest(ctx context.Context, req *pb.GetLatestRequest) (*pb.GetLatestResponse, error) {
	if v, err := s.rdb.Get(ctx, "latest:"+req.City).Result(); err == nil {
		var r pb.Reading
		if json.Unmarshal([]byte(v), &r) == nil {
			return &pb.GetLatestResponse{Reading: &r, Found: true}, nil
		}
	}

	var r pb.Reading
	var observed time.Time
	err := s.db.QueryRowContext(ctx,
		`SELECT city, latitude, longitude, temperature_c, windspeed_kph, observed_at, source
		 FROM weather_readings WHERE city=$1 ORDER BY observed_at DESC LIMIT 1`, req.City).
		Scan(&r.City, &r.Latitude, &r.Longitude, &r.TemperatureC, &r.WindspeedKph, &observed, &r.Source)
	if err == sql.ErrNoRows {
		return &pb.GetLatestResponse{Found: false}, nil
	}
	if err != nil {
		return nil, err
	}

	r.ObservedAt = observed.Format(time.RFC3339)
	return &pb.GetLatestResponse{Reading: &r, Found: true}, nil
}

// seedCities inserts the initial CITIES list into the cities table once,
// so the very first boot has something to show before anyone adds a city
// through the UI. Safe to call on every startup, not just the first one -
// ON CONFLICT DO NOTHING means re-running this against an already-seeded
// database is a harmless no-op.
func seedCities(db *sql.DB, csv string) {
	for _, c := range parseCities(csv) {
		_, err := db.Exec(
			`INSERT INTO cities (name, latitude, longitude) VALUES ($1,$2,$3)
			 ON CONFLICT (name) DO NOTHING`, c.Name, c.Lat, c.Lon)
		if err != nil {
			log.Printf("store: seed city %s: %v", c.Name, err)
		}
	}
}
