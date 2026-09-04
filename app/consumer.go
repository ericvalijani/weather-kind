package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	pb "weather/genproto"

	amqp "github.com/rabbitmq/amqp091-go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// runConsumer is the entire life of the `consumer` mode: connect to store
// (gRPC) and RabbitMQ, then sit in a loop forever, taking each message off
// the queue and asking store to persist it. This is the only thing api's
// fetch loop is decoupled from - if store or RabbitMQ is briefly down, api
// keeps fetching from Open-Meteo and queuing messages; consumer just picks
// up the backlog once things recover, nothing gets silently dropped by api
// itself. (Whether the queue itself can lose messages is a different,
// separate question - see the auto-ack note near the bottom of this file.)
func runConsumer() {
	amqpURL := "amqp://" + getenv("RABBITMQ_DEFAULT_USER", "admin") + ":" +
		getenv("RABBITMQ_DEFAULT_PASS", "") + "@" +
		getenv("AMQP_HOST", "rabbitmq") + ":" + getenv("AMQP_PORT", "5672") + "/"
	queue := getenv("QUEUE", "weather.readings")
	storeAddr := getenv("STORE_ADDR", "weather-store:9090")

	// gRPC connections don't actually dial immediately - grpc.NewClient
	// just prepares the client, the real connection attempt happens lazily
	// on the first call. So this can't fail just because store isn't up
	// yet; that would only surface later, on the first AddReading call.
	conn, err := grpc.NewClient(storeAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("consumer: cannot create store client: %v", err)
	}
	defer conn.Close()
	client := pb.NewWeatherStoreClient(conn)

	// RabbitMQ, unlike gRPC above, connects eagerly - amqp.Dial actually
	// opens a TCP connection right away, so it genuinely can fail if
	// RabbitMQ isn't ready yet. Retry with the same pattern used
	// throughout this project (30 attempts, 2s apart) rather than crash
	// and rely on Docker to restart us into the same race condition.
	var mq *amqp.Connection
	for i := 0; i < 30; i++ {
		mq, err = amqp.Dial(amqpURL)
		if err == nil {
			break
		}
		log.Printf("consumer: waiting for rabbitmq: %v", err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("consumer: cannot connect rabbitmq: %v", err)
	}
	defer mq.Close()

	ch, err := mq.Channel()
	if err != nil {
		log.Fatalf("consumer: channel: %v", err)
	}
	defer ch.Close()

	// Declaring the queue here too (api also declares it before publishing)
	// is intentional, not redundant - RabbitMQ's queue declaration is
	// idempotent, and this way consumer works correctly even if it happens
	// to start up before api ever has.
	if _, err := ch.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		log.Fatalf("consumer: queue declare: %v", err)
	}

	// auto-ack=true (the third `true` below) means RabbitMQ considers a
	// message delivered - and removes it from the queue - the moment it's
	// handed to this process, before we've actually stored it anywhere.
	// If this process crashes between receiving a message and finishing
	// the AddReading call below, that one reading is lost. Fine for a
	// weather app polling every few minutes; would be worth switching to
	// manual ack (only acknowledging after AddReading succeeds) for
	// anything where losing a message actually matters.
	msgs, err := ch.Consume(queue, "", true, false, false, false, nil)
	if err != nil {
		log.Fatalf("consumer: consume: %v", err)
	}

	log.Println("consumer: waiting for messages")
	for d := range msgs {
		var r reading
		if err := json.Unmarshal(d.Body, &r); err != nil {
			log.Printf("consumer: bad message: %v", err)
			continue
		}

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		resp, err := client.AddReading(ctx, &pb.Reading{
			City:         r.City,
			Latitude:     r.Latitude,
			Longitude:    r.Longitude,
			TemperatureC: r.TemperatureC,
			WindspeedKph: r.WindspeedKph,
			ObservedAt:   r.ObservedAt,
			Source:       r.Source,
		})
		cancel()
		if err != nil {
			log.Printf("consumer: addReading: %v", err)
			continue
		}
		log.Printf("consumer: stored id=%d city=%s", resp.Id, r.City)
	}
}
