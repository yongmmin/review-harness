'use strict'
// Hidden tests: copied to test/accept/ in the finished fixture by dev-score.sh, never shown to the agent.
const { test, before, after } = require('node:test')
const assert = require('node:assert/strict')
const { start, getJson } = require('../helpers')
const { createApp } = require('../../src/app')

let api
let paidIds
before(async () => {
  api = await start(createApp())
  const all = await getJson(`${api.url}/orders?limit=50`)
  paidIds = all.body.items.filter((o) => o.status === 'paid').map((o) => o.id)
})
after(() => api.close())

test('status=paid returns only the paid orders', async () => {
  const { status, body } = await getJson(`${api.url}/orders?status=paid`)
  assert.equal(status, 200)
  assert.ok(body.items.every((o) => o.status === 'paid'))
  assert.deepEqual(body.items.map((o) => o.id), paidIds)
})

test('without status, paging is unchanged', async () => {
  const { status, body } = await getJson(`${api.url}/orders?page=1&limit=5`)
  assert.equal(status, 200)
  assert.deepEqual(body.items.map((o) => o.id), [1, 2, 3, 4, 5])
  assert.equal(body.total, 12)
})

test('an unknown status is a 400 in the API error format', async () => {
  const { status, body } = await getJson(`${api.url}/orders?status=bogus`)
  assert.equal(status, 400)
  assert.deepEqual(Object.keys(body).sort(), ['error', 'message'])
  assert.equal(typeof body.error, 'string')
  assert.equal(typeof body.message, 'string')
})

test('the filter applies before paging', async () => {
  const { status, body } = await getJson(`${api.url}/orders?status=paid&page=2&limit=2`)
  assert.equal(status, 200)
  assert.deepEqual(body.items.map((o) => o.id), paidIds.slice(2, 4))
})
