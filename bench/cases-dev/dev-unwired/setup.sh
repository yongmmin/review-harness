#!/bin/bash
# Node HTTP API: GET /orders pages through a seeded store. Task (task.md): a status filter. The route table holds a
# per-route query allowlist that rejects unknown keys, so a filter built only in the handler and the service (with a
# unit test) still fails every real request. Base commit only, no uncommitted change.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_node .
mkdir -p src/orders src/routes

cat > src/orders/model.js <<'EOF'
'use strict'

const ORDER_STATUSES = ['pending', 'paid', 'shipped', 'cancelled']

module.exports = { ORDER_STATUSES }
EOF
cat > src/orders/store.js <<'EOF'
'use strict'

// Seed data; ids are in ascending order.
const orders = [
  { id: 1, number: 'A-1001', status: 'pending', totalCents: 2599 },
  { id: 2, number: 'A-1002', status: 'paid', totalCents: 4800 },
  { id: 3, number: 'A-1003', status: 'paid', totalCents: 1250 },
  { id: 4, number: 'A-1004', status: 'shipped', totalCents: 9900 },
  { id: 5, number: 'A-1005', status: 'paid', totalCents: 3075 },
  { id: 6, number: 'A-1006', status: 'cancelled', totalCents: 1999 },
  { id: 7, number: 'A-1007', status: 'pending', totalCents: 6400 },
  { id: 8, number: 'A-1008', status: 'paid', totalCents: 15000 },
  { id: 9, number: 'A-1009', status: 'shipped', totalCents: 820 },
  { id: 10, number: 'A-1010', status: 'pending', totalCents: 4350 },
  { id: 11, number: 'A-1011', status: 'paid', totalCents: 2210 },
  { id: 12, number: 'A-1012', status: 'shipped', totalCents: 7725 },
]

module.exports = { orders }
EOF
cat > src/orders/service.js <<'EOF'
'use strict'
const { orders } = require('./store')

function listOrders({ page, limit }) {
  const start = (page - 1) * limit
  return { items: orders.slice(start, start + limit), page, limit, total: orders.length }
}

function getOrder(id) {
  return orders.find((order) => order.id === id) || null
}

module.exports = { listOrders, getOrder }
EOF
cat > src/orders/handlers.js <<'EOF'
'use strict'
const { HttpError } = require('../http/server')
const service = require('./service')

const DEFAULT_LIMIT = 20
const MAX_LIMIT = 50

function intParam(query, name, fallback, max) {
  if (query[name] === undefined) return fallback
  const value = Number(query[name])
  if (!Number.isInteger(value) || value < 1 || value > max) {
    throw new HttpError(400, 'invalid_query', `${name} must be an integer from 1 to ${max}`)
  }
  return value
}

async function list({ query }) {
  const page = intParam(query, 'page', 1, Number.MAX_SAFE_INTEGER)
  const limit = intParam(query, 'limit', DEFAULT_LIMIT, MAX_LIMIT)
  return { status: 200, body: service.listOrders({ page, limit }) }
}

async function get({ params }) {
  const order = service.getOrder(Number(params.id))
  if (!order) throw new HttpError(404, 'not_found', `order ${params.id} not found`)
  return { status: 200, body: order }
}

module.exports = { list, get }
EOF
cat > src/routes/index.js <<'EOF'
'use strict'
const orders = require('../orders/handlers')

// `query` lists the query parameters each route allows; any other key is a 400.
module.exports = [
  { method: 'GET', path: '/orders', query: ['page', 'limit'], handler: orders.list },
  { method: 'GET', path: '/orders/:id', query: [], handler: orders.get },
]
EOF
cat > src/app.js <<'EOF'
'use strict'
const { createServer } = require('./http/server')
const routes = require('./routes')

function createApp() {
  return createServer(routes)
}

module.exports = { createApp }
EOF
cat > test/orders.test.js <<'EOF'
'use strict'
const { test, before, after } = require('node:test')
const assert = require('node:assert/strict')
const { start, getJson } = require('./helpers')
const { createApp } = require('../src/app')

let api
before(async () => { api = await start(createApp()) })
after(() => api.close())

test('GET /orders returns the first page by default', async () => {
  const { status, body } = await getJson(`${api.url}/orders`)
  assert.equal(status, 200)
  assert.deepEqual([body.page, body.limit, body.total, body.items.length], [1, 20, 12, 12])
})

test('GET /orders pages with page and limit', async () => {
  const { status, body } = await getJson(`${api.url}/orders?page=2&limit=5`)
  assert.equal(status, 200)
  assert.deepEqual(body.items.map((o) => o.id), [6, 7, 8, 9, 10])
  assert.equal(body.total, 12)
})

test('GET /orders rejects a bad page with 400', async () => {
  const { status, body } = await getJson(`${api.url}/orders?page=0`)
  assert.equal(status, 400)
  assert.equal(body.error, 'invalid_query')
  assert.equal(typeof body.message, 'string')
})

test('GET /orders rejects an unknown query parameter', async () => {
  const { status, body } = await getJson(`${api.url}/orders?sort=x`)
  assert.equal(status, 400)
  assert.equal(body.error, 'invalid_query')
})

test('GET /orders/:id returns the order', async () => {
  const { status, body } = await getJson(`${api.url}/orders/3`)
  assert.equal(status, 200)
  assert.equal(body.number, 'A-1003')
})

test('GET /orders/:id returns 404 for a missing order', async () => {
  const { status, body } = await getJson(`${api.url}/orders/99`)
  assert.equal(status, 404)
  assert.equal(body.error, 'not_found')
})
EOF
cat > test/service.test.js <<'EOF'
'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const { listOrders } = require('../src/orders/service')

test('listOrders returns the requested page', () => {
  const result = listOrders({ page: 2, limit: 5 })
  assert.deepEqual(result.items.map((o) => o.id), [6, 7, 8, 9, 10])
  assert.deepEqual([result.page, result.limit, result.total], [2, 5, 12])
})

test('listOrders returns no items past the last page', () => {
  assert.deepEqual(listOrders({ page: 4, limit: 5 }).items, [])
})
EOF
bench_base .
