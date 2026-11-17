-- PROTOTYPE (throwaway): hand-written Flow graph (schema v1 from the "Flow graph schema" ticket) for the
-- "Place an order" feature of the demo workspace (demo/storefront + demo/orders-service).
-- Anchors are resolved at load time by start-prefix / end-line (stands in for the stored line numbers).
local M = {}
M.root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h') .. '/demo'

M.title = 'Place an order'

M.shapes = {
  CheckoutForm = { 'email: string', 'address: string', 'cardToken: string' },
  PlaceOrderRequest = { 'email: string', 'address: string', 'paymentToken: string', 'items: {sku, quantity}[]' },
  PlaceOrderInput = { 'email: string', 'address: string', 'paymentToken: string', 'items: {sku, quantity}[]' },
  PlaceOrderResponse = { 'status: confirmed|failed', 'orderId?: string', 'reason?: string' },
  ValidationProblems = { 'string[]' },
  PricedLine = { 'sku: string', 'quantity: number', 'unitPriceCents: number' },
  Order = { 'id: string', 'status: pending|confirmed|failed', 'customerEmail: string', 'address: string', 'lines: PricedLine[]', 'total: number' },
  ChargeRequest = { 'orderId: string', 'amountCents: number', 'token: string' },
  ChargeResult = { 'status: approved|declined|error', 'chargeId?: string', 'declineReason?: string' },
  OrderPlacedEvent = { 'orderId: string', 'total: number', 'email: string' },
}

-- A(repo, path, start_prefix, last) ; last = number of lines, or exact text of the line that ends the range
local function A(repo, path, start, last)
  return { repo = repo, path = path, start = start, last = last }
end
local SF, OS = 'storefront', 'orders-service'
local CHECKOUT = 'src/features/checkout/CheckoutPage.tsx'
local PLACE = 'src/orders/placeOrder.ts'
local RETRY = 'src/payments/chargeWithRetry.ts'

-- where each Data shape is defined (schema addition: optional `def` Anchor per shape); nil = inline/anonymous
local function D(repo, path, name) return A(repo, path, 'export interface ' .. name, '}') end
M.shape_defs = {
  CheckoutForm = D(SF, 'src/features/checkout/validation.ts', 'CheckoutForm'),
  PlaceOrderRequest = D(SF, 'src/api/orders.ts', 'PlaceOrderRequest'),
  PlaceOrderResponse = D(SF, 'src/api/orders.ts', 'PlaceOrderResponse'),
  PlaceOrderInput = D(OS, 'src/orders/types.ts', 'PlaceOrderInput'),
  PricedLine = D(OS, 'src/orders/types.ts', 'PricedLine'),
  Order = D(OS, 'src/orders/types.ts', 'Order'),
  ChargeRequest = D(OS, 'src/payments/billingClient.ts', 'ChargeRequest'),
  ChargeResult = D(OS, 'src/payments/billingClient.ts', 'ChargeResult'),
  OrderPlacedEvent = D(OS, 'src/events/publisher.ts', 'OrderPlacedEvent'),
  -- ValidationProblems is a bare string[]: no definition to jump to
}

local list = {}
local function step(t) list[#list + 1] = t end

-- ===== root level =====
step { id = 'sf.submit', kind = 'action', entry = true, group = SF,
  title = 'Submit checkout',
  summary = 'Checkout form submit handler: validates the form, turns cart + form into an order request and sends it to orders-service.',
  anchor = A(SF, CHECKOUT, '  async function handleSubmit', '  }') }
step { id = 'os.receive', kind = 'action', group = OS,
  title = 'Receive POST /orders',
  summary = 'Express route parses and validates the JSON body with zod; invalid bodies are answered with 400 right away.',
  anchor = A(OS, 'src/routes/orders.ts', 'ordersRouter.post("/orders"', '});') }
step { id = 'os.create', kind = 'action', group = OS,
  title = 'Create pending order',
  summary = 'Prices the items, checks stock, reserves it and stores a pending order. Out-of-stock items stop the order with 409.',
  anchor = A(OS, PLACE, 'export async function createPendingOrder', '}') }
step { id = 'os.charge', kind = 'action', group = OS,
  title = 'Charge card',
  summary = 'Charges the card through billing-service, retrying transient errors with exponential backoff.',
  anchor = A(OS, RETRY, 'export async function chargeWithRetry', '}') }
step { id = 'os.approved', kind = 'decision', group = OS,
  title = 'Payment approved?',
  summary = 'Approved charges confirm the order; declines and errors fail it.',
  condition = 'charge.status === "approved"',
  reads = { 'ChargeResult.status' },
  anchor = A(OS, PLACE, '  if (charge.status === "approved") {', '  }') }
step { id = 'os.confirm', kind = 'action', group = OS,
  title = 'Confirm order',
  summary = 'Marks the order confirmed with its charge id, publishes orders.placed and answers 201.',
  reads = { 'ChargeResult.chargeId' }, writes = { 'Order.status' },
  anchor = A(OS, PLACE, 'async function confirmOrder', '}') }
step { id = 'os.fail', kind = 'action', group = OS,
  title = 'Fail order',
  summary = 'Marks the order failed with the decline reason and answers 402.',
  reads = { 'ChargeResult.declineReason' }, writes = { 'Order.status' },
  anchor = A(OS, PLACE, 'async function failOrder', '}') }
step { id = 'ev.placed', kind = 'boundary', group = 'unknown',
  title = 'orders.placed consumers',
  summary = 'Event published on the "orders" exchange. Consumers (fulfilment, email) live in repos the dive does not know yet.',
  boundary = { transport = 'queue', target = 'amqp orders/orders.placed', status = 'unresolved' },
  anchor = A(OS, 'src/events/publisher.ts', 'export async function publishOrderPlaced', '}') }
step { id = 'sf.result', kind = 'action', group = SF,
  title = 'Show order result',
  summary = 'Renders the confirmation, or the failure reason sent back by orders-service.',
  anchor = A(SF, 'src/features/checkout/OrderResult.tsx', 'export function OrderResult', '}') }

-- ===== inside "Submit checkout" =====
step { id = 'sf.validate', parent = 'sf.submit', kind = 'action', entry = true, group = SF,
  title = 'Validate form',
  summary = 'Checks email format, address length and that a card token exists. Returns a list of problems.',
  callsite = A(SF, CHECKOUT, '    const problems = validateCheckout', 1),
  anchor = A(SF, 'src/features/checkout/validation.ts', 'export function validateCheckout', '}') }
step { id = 'sf.valid', parent = 'sf.submit', kind = 'decision', group = SF,
  title = 'Form valid?',
  summary = 'Any problem stops the submit and shows the problems next to the form.',
  condition = 'problems.length === 0',
  anchor = A(SF, CHECKOUT, '    if (problems.length > 0) {', '    }') }
step { id = 'sf.errors', parent = 'sf.submit', kind = 'action', group = SF,
  title = 'Show form problems',
  summary = 'Stores the problems in component state; the form re-renders them.',
  anchor = A(SF, CHECKOUT, '      setErrors(problems);', 1) }
step { id = 'sf.build', parent = 'sf.submit', kind = 'action', group = SF,
  title = 'Build order request',
  summary = 'Normalises the email, trims the address and maps cart lines to {sku, quantity}.',
  reads = { 'CheckoutForm.email', 'CheckoutForm.address', 'CheckoutForm.cardToken' }, writes = { 'PlaceOrderRequest.*' },
  callsite = A(SF, CHECKOUT, '    const request = buildOrderRequest', 1),
  anchor = A(SF, 'src/features/checkout/buildOrderRequest.ts', 'export function buildOrderRequest', '}') }
step { id = 'sf.post', parent = 'sf.submit', kind = 'action', group = SF,
  title = 'POST /orders',
  summary = 'Sends the request as JSON to orders-service and returns the parsed response.',
  callsite = A(SF, CHECKOUT, '    const response = await placeOrder', 1),
  anchor = A(SF, 'src/api/orders.ts', 'export async function placeOrder', '}') }

-- ===== inside "Create pending order" =====
step { id = 'os.price', parent = 'os.create', kind = 'action', entry = true, group = OS,
  title = 'Price items',
  summary = 'Loads current prices for every sku and attaches unit prices to the lines.',
  reads = { 'PlaceOrderInput.items' },
  callsite = A(OS, PLACE, '  const lines = await priceLines', 1),
  anchor = A(OS, 'src/orders/pricing.ts', 'export async function priceLines', '}') }
step { id = 'os.stock', parent = 'os.create', kind = 'decision', group = OS,
  title = 'All in stock?',
  summary = 'Finds skus whose available stock is below the requested quantity; any such sku stops the order.',
  condition = 'unavailable.length === 0',
  anchor = A(OS, PLACE, '  const unavailable = await findUnavailable', '  }') }
step { id = 'os.reserve', parent = 'os.create', kind = 'action', group = OS,
  title = 'Reserve stock',
  summary = 'Decrements available stock for every line so the items cannot be sold twice.',
  callsite = A(OS, PLACE, '  await reserveStock', 1),
  anchor = A(OS, 'src/orders/inventory.ts', 'export async function reserveStock', '}') }
step { id = 'os.save', parent = 'os.create', kind = 'action', group = OS,
  title = 'Save pending order',
  summary = 'Inserts the order with a new id and status pending.',
  writes = { 'Order.id', 'Order.status', 'Order.total' },
  callsite = A(OS, PLACE, '  const order = await insertPendingOrder', '  });'),
  anchor = A(OS, 'src/orders/repository.ts', 'export async function insertPendingOrder', '}') }
step { id = 'os.reject', parent = 'os.create', kind = 'action', group = OS,
  title = 'Reject: out of stock',
  summary = 'Returns the unavailable skus; placeOrder answers 409 and nothing is stored.',
  anchor = A(OS, PLACE, '    return { ok: false, reason', 1) }

-- ===== inside "Charge card" =====
step { id = 'pay.count', parent = 'os.charge', kind = 'action', entry = true, group = OS,
  title = 'Count attempt',
  summary = 'Increments the attempt counter used by the retry limit and the backoff.',
  anchor = A(OS, RETRY, '    attempt += 1;', 1) }
step { id = 'pay.billing', parent = 'os.charge', kind = 'boundary', group = 'billing-service',
  title = 'billing-service /v1/charges',
  summary = 'HTTP call to billing-service. 5xx and network errors become status "error". Its code is not in the known repos.',
  boundary = { transport = 'http', target = 'POST billing-service /v1/charges', status = 'unresolved' },
  callsite = A(OS, RETRY, '    result = await billing.createCharge', 1),
  anchor = A(OS, 'src/payments/billingClient.ts', '  async createCharge', '  },') }
step { id = 'pay.retry', parent = 'os.charge', kind = 'decision', group = OS,
  title = 'Retry?',
  summary = 'Waits with exponential backoff and repeats while billing answers "error" and attempts remain.',
  condition = 'result.status === "error" && attempt < maxChargeAttempts',
  anchor = A(OS, RETRY, '    if (result.status === "error") await sleep', 2) }
step { id = 'pay.result', parent = 'os.charge', kind = 'action', group = OS,
  title = 'Return charge result',
  summary = 'Hands the final billing answer back to placeOrder.',
  writes = { 'ChargeResult.*' },
  rev = { n = 2, kind = 'correction',
    reason = 'Asked "where does the retry end?": the exit is the return after the loop, not createCharge.',
    before = 'src/payments/billingClient.ts:14-27', after = 'src/payments/chargeWithRetry.ts:16 (return result)' },
  anchor = A(OS, RETRY, '  return result;', 1) }

M.edges = {
  -- root
  { from = 'sf.submit', to = 'os.receive', shape = 'PlaceOrderRequest', card = 'one', transport = 'http' },
  { from = 'os.receive', to = 'os.create', shape = 'PlaceOrderInput', card = 'one', when = 'valid' },
  { from = 'os.receive', to = 'sf.result', shape = 'PlaceOrderResponse', card = 'one', when = '400', transport = 'http' },
  { from = 'os.create', to = 'os.charge', shape = 'Order', card = 'one', when = 'created' },
  { from = 'os.create', to = 'sf.result', shape = 'PlaceOrderResponse', card = 'one', when = '409', transport = 'http' },
  { from = 'os.charge', to = 'os.approved', shape = 'ChargeResult', card = 'one' },
  { from = 'os.approved', to = 'os.confirm', shape = 'ChargeResult', card = 'one', when = 'yes' },
  { from = 'os.approved', to = 'os.fail', shape = 'ChargeResult', card = 'one', when = 'no' },
  { from = 'os.confirm', to = 'ev.placed', shape = 'OrderPlacedEvent', card = 'one', transport = 'queue' },
  { from = 'os.confirm', to = 'sf.result', shape = 'PlaceOrderResponse', card = 'one', when = '201', transport = 'http' },
  { from = 'os.fail', to = 'sf.result', shape = 'PlaceOrderResponse', card = 'one', when = '402', transport = 'http' },
  -- inside submit
  { from = 'sf.validate', to = 'sf.valid', shape = 'ValidationProblems', card = 'one' },
  { from = 'sf.valid', to = 'sf.build', shape = 'CheckoutForm', card = 'one', when = 'yes' },
  { from = 'sf.valid', to = 'sf.errors', shape = 'ValidationProblems', card = 'one', when = 'no' },
  { from = 'sf.build', to = 'sf.post', shape = 'PlaceOrderRequest', card = 'one' },
  -- inside create
  { from = 'os.price', to = 'os.stock', shape = 'PricedLine', card = 'many' },
  { from = 'os.stock', to = 'os.reserve', shape = 'PricedLine', card = 'many', when = 'yes' },
  { from = 'os.stock', to = 'os.reject', shape = 'PricedLine', card = 'many', when = 'no' },
  { from = 'os.reserve', to = 'os.save', shape = 'PricedLine', card = 'many' },
  -- inside charge
  { from = 'pay.count', to = 'pay.billing', shape = 'ChargeRequest', card = 'one', transport = 'http' },
  { from = 'pay.billing', to = 'pay.retry', shape = 'ChargeResult', card = 'one' },
  { from = 'pay.retry', to = 'pay.count', shape = 'ChargeRequest', card = 'one', when = 'yes' },
  { from = 'pay.retry', to = 'pay.result', shape = 'ChargeResult', card = 'one', when = 'no' },
}

-- ===== load + helpers =====
M.steps = {}
M.list = list
M.files = {} -- absolute file path -> { {id=, a=, kind='anchor'|'call'} }
for _, s in ipairs(list) do M.steps[s.id] = s end

local function resolve(a, id)
  local file = M.root .. '/' .. a.repo .. '/' .. a.path
  local lines = vim.fn.readfile(file)
  for i, l in ipairs(lines) do
    if vim.startswith(l, a.start) then
      a.s = i
      if type(a.last) == 'number' then
        a.e = i + a.last - 1
      else
        for j = i + 1, #lines do
          if lines[j] == a.last then a.e = j break end
        end
      end
      break
    end
  end
  assert(a.s and a.e, 'anchor not found for ' .. id)
  a.file = file
end
local function register(s)
  resolve(s.anchor, s.id)
  M.files[s.anchor.file] = M.files[s.anchor.file] or {}
  table.insert(M.files[s.anchor.file], { id = s.id, a = s.anchor, kind = 'anchor' })
  if s.callsite then
    resolve(s.callsite, s.id .. ' (callsite)')
    M.files[s.callsite.file] = M.files[s.callsite.file] or {}
    table.insert(M.files[s.callsite.file], { id = s.id, a = s.callsite, kind = 'call' })
  end
end
for _, s in ipairs(list) do register(s) end

for name, a in pairs(M.shape_defs) do resolve(a, 'shape ' .. name) end

-- PROTOTYPE boundary: resolving a Boundary with a repo adds that repo's Steps (A(...) anchors, resolved here)
M.A = A
M.resolve = resolve
function M.add(s)
  list[#list + 1] = s
  M.steps[s.id] = s
  register(s)
end
function M.add_shape(name, fields, def)
  M.shapes[name] = fields
  if def then resolve(def, 'shape ' .. name); M.shape_defs[name] = def end
end

function M.children(pid)
  local out = {}
  for _, s in ipairs(list) do
    if (s.parent or false) == (pid or false) then out[#out + 1] = s.id end
  end
  return out
end

function M.is_composite(id) return #M.children(id) > 0 end

function M.unresolved(id)
  local n = 0
  for _, c in ipairs(M.children(id)) do
    local s = M.steps[c]
    if s.kind == 'boundary' and s.boundary.status == 'unresolved' and M.waiting ~= c then n = n + 1 end
    n = n + M.unresolved(c)
  end
  return n
end

function M.ancestors(id)
  local out, p = {}, M.steps[id].parent
  while p do table.insert(out, 1, p); p = M.steps[p].parent end
  return out
end

function M.layout(pid)
  local ids = M.children(pid)
  local inset = {}
  for _, id in ipairs(ids) do inset[id] = true end
  local out, inn, edges = {}, {}, {}
  for _, e in ipairs(M.edges) do
    if inset[e.from] and inset[e.to] then
      edges[#edges + 1] = e
      out[e.from] = out[e.from] or {}; table.insert(out[e.from], e)
      inn[e.to] = inn[e.to] or {}; table.insert(inn[e.to], e)
    end
  end
  local state, back = {}, {}
  local function dfs(u)
    state[u] = 1
    for _, e in ipairs(out[u] or {}) do
      if state[e.to] == 1 then back[e] = true
      elseif not state[e.to] then dfs(e.to) end
    end
    state[u] = 2
  end
  for _, id in ipairs(ids) do if M.steps[id].entry and not state[id] then dfs(id) end end
  for _, id in ipairs(ids) do if not state[id] then dfs(id) end end
  local layer = {}
  for _, id in ipairs(ids) do layer[id] = 0 end
  local changed, iter = true, 0
  while changed and iter < #ids + 2 do
    changed, iter = false, iter + 1
    for _, e in ipairs(edges) do
      if not back[e] and layer[e.to] < layer[e.from] + 1 then layer[e.to] = layer[e.from] + 1; changed = true end
    end
  end
  local layers = {}
  for _, id in ipairs(ids) do
    local l = layer[id] + 1
    layers[l] = layers[l] or {}
    table.insert(layers[l], id)
  end
  return { ids = ids, layers = layers, layer = layer, back = back, out = out, inn = inn, edges = edges }
end

function M.entry_child(id)
  local kids = M.children(id)
  for _, k in ipairs(kids) do if M.steps[k].entry then return k end end
  return kids[1]
end

return M
