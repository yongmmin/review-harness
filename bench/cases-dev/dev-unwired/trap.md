# Trap

The obvious change validates `status` in `src/orders/handlers.js`, filters in `listOrders` before paging, and
proves it with a unit test of the service: every test passes. But `src/routes/index.js` lists the query parameters
`GET /orders` allows (`page`, `limit`), and the server rejects any other key before the handler runs, so every real
request with `status` gets `400 invalid_query`. Only a test over HTTP shows it (`trap.patch`).

Plan line that blocks it: a `Done When` item with an HTTP-level check (`GET /orders?status=paid` → 200, only paid
orders) / `Callers/Consumers`: the `src/routes/index.js` allowlist; reviewer `[goal]`.
