# orders-service

Owns orders: pricing, stock reservation, payment orchestration and the `orders.placed` event.

- HTTP: `POST /orders`, `GET /orders/:id`
- Calls `billing-service` (`POST /v1/charges`) to charge cards
- Publishes `orders.placed` on RabbitMQ; consumed by fulfilment and email (other repos)
