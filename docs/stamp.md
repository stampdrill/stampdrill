# Stamp

Stamp is the file format Stampdrill reads. A `.stamp` file is plain text: you can
write it in any editor, keep it in git next to the code it talks to, run it
from a terminal with `stamp run` and open the same folder in the app.

```
@base = {{host}}/api

### Login
POST {{base}}/login
Content-Type: application/json

{ "username": "{{username}}", "password": "{{password}}" }

> assert status == 200
> set token = body.token

### Me
@needs login
@auth bearer {{token}}
GET {{base}}/me

> assert body.name != null
```

## Files and workspaces

A workspace is a folder. Every `.stamp` file below it is part of the workspace,
and folders are only there to group files.

`environment.stamp` at the root of the workspace is where dimensions and
variable sets live (see [Environments](#environments)). The command-line tool
finds the workspace by walking up from the file you give it until it sees an
`environment.stamp`.

## Requests

A file is a preamble followed by requests. Requests are separated by a line
starting with `###`; whatever follows the `###` is the request's title.

Inside a request the order is fixed:

1. variables and directives
2. the request line
3. headers
4. an empty line, then the body
5. response script lines starting with `>`

```
### Create a post
@timeout 10s
POST https://example.com/posts HTTP/1.1
Content-Type: application/json
# X-Debug: 1

{ "title": "Hello" }

> assert status == 201
```

The request line is a method and a URL, optionally followed by the HTTP
version. A line that starts with `http://`, `https://` or `{{` is a `GET`. When
the URL has no scheme, `http://` is assumed.

Headers are `Name: value` lines. A header that is commented out (`# Name: value`
or `// Name: value`) is kept as a disabled header, which the app shows with its
checkbox off.

The body is everything after the first empty line up to the script, the next
`###` or the end of the file. Leading and trailing blank lines are dropped.
When the body is a single line of the form `< path`, the body is read from that
file, relative to the `.stamp` file. When a body starts with `{` or `[` and no
`Content-Type` header was given, `application/json` is sent.

A file with a single request doesn't need `###` at all.

### Forms and uploads

With a `multipart/form-data` or `application/x-www-form-urlencoded`
`Content-Type`, a body made of `name = value` lines is sent as a form. In a
multipart form, `name = < ./path` attaches a file:

```
POST https://example.com/upload
Content-Type: multipart/form-data

title = Holiday
photo = < ./photos/beach.jpg
```

### WebSockets

`WS url` opens a WebSocket (an `http` URL becomes `ws`, `https` becomes `wss`).
Headers go into the handshake, and a body, if there is one, is sent as the first
message. Then the response script runs against the open connection:

| Statement | |
|---|---|
| `send value` | sends text; objects and arrays are sent as JSON |
| `receive`, `receive 5s` | waits for the next message (10 seconds by default); `message` is its text and `data` its JSON, both `null` when nothing came |
| `wait 500ms` | pauses |
| `close` | closes the connection; it also closes when the script ends |

```
WS wss://ws.postman-echo.com/raw

> send json({ type: "hello" })
> receive 5s
> assert data.type == "hello"
```

The conversation is the response body, and the app shows it as a timeline.

### GraphQL

`GRAPHQL url` sends the body as a GraphQL operation: a JSON `POST` with the query,
and with the variables when a JSON object follows the query after an empty line.
Scripts read `body.data` and `body.errors`.

```
GRAPHQL https://countries.trevorblades.com/graphql

query Country($code: ID!) {
  country(code: $code) { name capital }
}

{ "code": "{{countryCode}}" }
```

### WebRTC

A call only connects when its ICE servers work, so they can be checked like any
other endpoint. `STUN` and `TURN` take the URLs `RTCPeerConnection` takes:
`stun:host:port`, `turn:host:port?transport=tcp`, `turns:host:port` for TLS.

A STUN request sends a Binding request and reports the address the server saw.
A TURN request allocates a relay with the credentials from `@auth basic`, then
releases it. The status is 200, or the server's STUN error code: 401 when
credentials are missing or wrong, 437, 438, 486 and so on.

```
STUN stun:stun.l.google.com:19302

> assert body.mapped.port > 0
> assert body.rtt < 200

###
@auth basic {{turnUser}} {{secret(turnPassword)}}
TURN turns:turn.example.com:5349

> assert status == 200
> assert body.relayed != null
```

| Field | |
|---|---|
| `mapped` | `address`, `port` and `family` of your public address |
| `relayed` | the relay a TURN server allocated |
| `lifetime` | seconds the relay would have lasted |
| `rtt` | round trip of the answering request, in milliseconds |
| `local` | the local address the check used |
| `behindNAT` | whether the public address differs from the local one |
| `realm`, `authenticated`, `software`, `error` | what the server said |

Signaling is up to the application; a `WS` request with `send` and `receive`
covers the usual offer and answer exchange.

### MCP servers

`MCP` connects to a [Model Context Protocol](https://modelcontextprotocol.io)
server the way an MCP client would, so a server can be tested as you build it.
The target is a Streamable HTTP endpoint, or `stdio:` and the command that starts
the server, run from the file's folder:

```
MCP http://localhost:3001/mcp
MCP stdio: node build/index.js --verbose
```

Headers and `@auth` go with every HTTP message. The client does the handshake,
lists the server's tools, resources and prompts, and then runs the script:

```
### Weather tools
MCP stdio: npx -y @modelcontextprotocol/server-everything

> assert server.serverInfo.name == "mcp-servers/everything"
> assert toolNames contains "echo"
> assert call("echo", { message: "hi" }).text == "Echo: hi"
> let sum = call("get-sum", { a: 2, b: 40 })
> assert sum.text contains "42"
> assert !sum.isError
```

| Name | |
|---|---|
| `server` | the `initialize` result: `serverInfo`, `capabilities`, `protocolVersion`, `instructions` |
| `tools`, `toolNames` | the tools, and their names |
| `resources`, `resourceTemplates` | the resources and resource templates |
| `prompts`, `promptNames` | the prompts, and their names |
| `notifications` | every notification received so far |

| Function | |
|---|---|
| `call(tool, arguments, meta)` | calls a tool; `meta` becomes `_meta`, such as `{ progressToken: "p1" }` |
| `read(uri)` | reads a resource |
| `getPrompt(name, arguments)` | gets a prompt |
| `ping()` | pings the server |
| `request(method, params)` | sends any request |
| `notify(method, params)` | sends a notification; it can stand on its own line |

Results are what the server answered, with `text` added: the text of the
content, joined. A JSON-RPC error doesn't stop the script. It comes back as
`{ error: { code, message } }`, and for `call` also sets `isError`, so both kinds
of tool failure can be checked the same way:

```
> let missing = call("no-such-tool", {})
> assert missing.isError
> assert request("unknown/method").error.code == -32601
```

Server calls are made before the rest of their statement runs, so they can't be
used inside a function (`=>`); call first with `let`, then use the result.

`send` sends a JSON-RPC message exactly as written, and `receive`, `receive 2s`
takes the next notification, or the response to something sent with `send`, as
`message` and `data`. `close` ends the session, which otherwise ends with the
script.

When the server asks the client for something, these directives answer:

| Directive | |
|---|---|
| `@sampling reply Sunny, 24°C` | the text returned for `sampling/createMessage` |
| `@elicitation accept { "name": "Ada" }` | accepts an elicitation with this content; also `decline` and `cancel` |
| `@roots file:///work/app, file:///work/lib` | the roots returned for `roots/list` |

Each one also declares the capability in the handshake, and a request the file
doesn't answer gets a "method not found" error. The body of the response lists
what the server offers, and every message in either direction appears in the
app as a timeline.

In the app, the Tools, Resources and Prompts tabs under an MCP request open a
live session with the server: each tool gets a form built from its input schema,
templates get a field per variable, and **Save as Test** adds the call, with
assertions on what came back, to the request's script. The Mac App Store app
runs in a sandbox that can't start other programs, so stdio servers run from
the command-line tool.

### Names

Requests are referred to by name: from `@needs`, from scripts (`login.body`)
and from the command line. The name is taken from, in order:

- `@name login`
- the title, turned into an identifier: `### Start a chat` becomes `startAChat`
- the file name, for untitled requests

## Comments

Lines starting with `#` or `//` are comments, except inside a body, where every
line is part of the body.

## Variables

```
@host = localhost:8080
let started = now()
```

`@name = text` declares a text variable. The value is everything after `=`,
with `{{ }}` interpolation.

`let name = expression` declares a variable computed by an expression.

Variables declared before the first request belong to the file. Variables
declared inside a request, before its request line, belong to that request.

Variables are evaluated lazily, when a request uses them, and the most specific
definition wins. From lowest to highest priority:

1. the environment (matching variable sets)
2. the file
3. the session (values stored with `set`, responses of named requests)
4. the request
5. overrides (`--var` on the command line)

A variable can refer to an outer definition of itself:

```
@token = Bearer {{token}}
```

### Interpolation

`{{ expression }}` works in the URL, header values, bodies, text variables and
`@auth` arguments.

In the URL and in header values, `$name` is replaced by the variable `name` when
such a variable exists, and left as it is otherwise.

Write `\{{` for a literal `{{`.

## Expressions

Expressions are small and familiar:

| | |
|---|---|
| literals | `"text"`, `'text'`, `42`, `1.5`, `true`, `false`, `null` |
| collections | `[1, 2]`, `{ name: "Rojîn", "an id": 7 }` |
| access | `body.items[0].name`, `headers["content-type"]`, `items[-1]` |
| calls | `upper(name)`, `bearer(token)` |
| arithmetic | `+ - * / %`; `+` joins strings and arrays and merges objects |
| comparison | `== != < <= > >=`, `contains`, `matches` (regular expression) |
| logic | `&& \|\| !`, or `and or not` |
| defaults | `token ?? "anonymous"` also covers variables that don't exist |
| conditional | `status == 200 ? "ok" : "failed"` |

Reading a property of `null` gives `null`, so `body.user.name` doesn't fail
when there is no user. Using a variable that doesn't exist does.

Equality is strict: `200 == "200"` is `false`.

`env.name` reads the variable `name` and gives `null` when it doesn't exist.

### Functions

| Function | |
|---|---|
| `uuid()` | random UUID |
| `now()` | current time, ISO 8601 |
| `timestamp()` | seconds since 1970 |
| `random(max)`, `randomInt(min, max)` | random whole numbers |
| `json(value)`, `parseJson(text)` | to and from JSON |
| `string(value)`, `number(value)`, `length(value)`, `keys(object)` | conversions |
| `upper`, `lower`, `trim`, `replace(text, find, with)`, `split(text, sep)`, `join(array, sep)` | text |
| `urlencode`, `base64`, `base64decode`, `sha256`, `hmacSha256(key, message)` | encoding |
| `getenv(name)` | process environment variable |
| `bearer(token)`, `basic(user, password)` | `Authorization` values |
| `localhost(port)`, `onPort(host, port)` | `localhost:8080`; port 80 is left out |
| `secret(value)` | marks a value as secret; it is masked in output |

Constants: `contentType.json`, `.xml`, `.form`, `.multipart`, `.text`, `.html`,
and ports `HTTP`, `HTTPS`, `WEB`, `WEB_PROXY`, `TOMCAT`, `NGINX`, `SYNAPSE`,
`SYNAPSE_HTTP`, `SOLR`, `MYSQL`, `POSTGRES`, `MONGODB`, `REDIS`, `ZOOKEEPER`.

### Functions of your own

```
fn bearerFor(user) = "Bearer " + user.token
fn page(n, size) = "?page=" + n + "&size=" + (size ?? 20)
```

`fn` declares a function. Like variables, it can live in a file, in a request,
or in a `vars` block of `environment.stamp` to be shared by every file.

Functions can also be written inline as lambdas, `x => x.id` or
`(total, x) => total + x.price`, and passed to:

| Function | |
|---|---|
| `map(list, fn)`, `flatMap(list, fn)` | transform every item |
| `filter(list, fn)`, `find(list, fn)` | keep matching items, or the first one |
| `all(list, fn)`, `any(list, fn)`, `count(list, fn?)` | check items |
| `sum(list, fn?)`, `min(list, fn?)`, `max(list, fn?)` | numbers |
| `sortBy(list, fn)`, `groupBy(list, fn)`, `unique(list)` | reorder and group |
| `reduce(list, fn, initial)`, `range(end)`, `range(start, end)` | everything else |

```
> assert all(body.items, item => item.price > 0)
> set cheapest = min(body.items, item => item.price)
```

### Sample data

`fake` gives realistic values: `fake.firstName`, `fake.name`, `fake.email`,
`fake.username`, `fake.phone`, `fake.avatar`, `fake.birthDate`, `fake.jobTitle`,
`fake.company`, `fake.product`, `fake.price`, `fake.currency`, `fake.iban`,
`fake.creditCard` (test numbers), `fake.street`, `fake.city`, `fake.country`,
`fake.zip`, `fake.latitude`, `fake.word`, `fake.sentence`, `fake.paragraph`,
`fake.url`, `fake.ipv4`, `fake.date`, `fake.pastDate`, `fake.futureDate`,
`fake.uuid`, `fake.id`, `fake.number`, `fake.bool`, and whole records:
`fake.person`, `fake.address`, `fake.organization`.

Random helpers: `uuid()`, `random(max)`, `randomInt(min, max)`,
`randomFloat(min, max, decimals)`, `randomString(length, alphabet)`,
`oneOf(list)`, `shuffle(list)`.

**Repeatable data.** Set a variable named `seed` and every `fake` value, `uuid()`
and random helper produces the same sequence on every run:

```
@seed = checkout-tests
```

**Related records.** `person(key)`, `address(key)` and `organization(key)` return
the same record for the same key, anywhere. Its fields belong together: the
email is made from the name.

```
{ "author": "{{person(7).name}}", "contact": "{{person(7).email}}" }
```

**From a schema.** `mock(schema)` builds a value from a JSON Schema: examples,
enums, formats (`email`, `uuid`, `date-time`, `uri`…), bounds and property names
all shape the result. Give a second argument to make it repeatable.

```
{{ json(mock(readJson("./schemas/user.json"), "user-1")) }}
```

`readJson(path)` and `readText(path)` read files next to the `.stamp` file.

## Directives

| Directive | |
|---|---|
| `@name login` | name the request |
| `@needs login, profile` | run these requests first, unless they already ran in this session |
| `@timeout 30s` | also `1500ms`, `2m`; default 30 seconds |
| `@no-redirect` | don't follow redirects |
| `@insecure` | don't verify TLS certificates |
| `@auth …` | authentication, see below |

### Authentication

```
@auth bearer {{token}}
@auth jwt {{idToken}}
@auth basic {{user}} {{password}}
@auth apikey X-API-Key {{key}}
@auth apikey api_key {{key}} query
@auth oauth2 client_credentials token_url={{idp}}/token client_id=stampdrill client_secret={{secret(clientSecret)}} scope="read write"
@auth oauth2 password token_url=… client_id=… username={{user}} password={{password}}
@auth none
```

`@auth` in the preamble applies to every request in the file; a request can
override it with its own `@auth`, including `@auth none`. A header written in the
request always wins over `@auth`.

For `oauth2`, a token is fetched from `token_url` before the request is sent
and reused until it expires. The settings are `token_url`, `client_id`,
`client_secret`, `scope`, `audience`, `username` and `password`.

## Response scripts

Lines starting with `>` after a request run once its response arrives.

```
> assert status == 200
> assert body.items.length > 0, "no items came back"
> let first = body.items[0]
> set postId = first.id
> print "created " + first.title
```

| Statement | |
|---|---|
| `assert condition` | records a passed or failed check; an optional message follows a comma |
| `set name = value` | stores a variable for every later request in the session |
| `save name = value` | like `set`, and also writes it to `environment.local.stamp` for the selected dimension values |
| `let name = value` | a variable for the rest of this script |
| `print value` | writes to the console |

Scripts can read `status`, `headers` (names in lower case), `body` (parsed when
it is JSON, text otherwise), `text`, `time` (milliseconds), `size` (bytes), `url`
and `response`, which holds all of them.

The response of a request that ran is also available to later requests under
the request's name: `{{login.body.token}}`, `> assert login.status == 200`.

## Test plans

A plan runs requests in order and checks what comes back between them. Plans
are written before the first request of a file.

```
plan Checkout {
  matrix env = staging|prod, userGroup = *
  data ./fixtures/users.csv
  parallel 4
  retry 2 every 500ms
  timeout 2m
  tags smoke

  setup { run logIn }

  step "Browse" {
    run listProducts with limit = 5
    expect status == 200
    expect time < 800, "listing took " + time + " ms"
    set productId = body[0].id
  }

  for each quantity in [1, 3] {
    run addToCart with productId = productId, quantity = quantity
    expect body.items.length > 0
  }

  if env == "staging" {
    run resetCart
  } else {
    print "leaving prod alone"
  }

  teardown { run logOut }
}
```

| Setting | |
|---|---|
| `matrix name = a\|b, other = *` | runs the plan once per combination; `*` is every value of a dimension |
| `data ./file.csv` | runs once per row of a CSV (with a header row) or a JSON array of objects; columns become variables |
| `parallel 4` | how many iterations run at the same time |
| `retry 2 every 500ms` | re-runs a failing `step` |
| `timeout 2m` | gives up on an iteration that takes longer |
| `tags a, b` | for `stamp test --tags` |

| Statement | |
|---|---|
| `run name`, `run name with a = expr, b = expr` | runs a request, with extra variables |
| `expect condition`, `expect condition, message` | checks the last response: `status`, `body`, `headers`, `time` |
| `set name = value`, `let name = value` | a variable for the rest of the iteration |
| `print value`, `wait 500ms` | |
| `step "title" { … }` | groups statements; retried as a whole |
| `repeat 3 { … }`, `for each item in list { … }` | loops; `index` counts from 0 |
| `if condition { … } else { … }` | |

Every iteration has its own session, so iterations never share tokens.

### Concurrency and race conditions

```
plan DoubleSpend {
  setup { run logIn }

  concurrently 10 {
    sync "ready"
    run withdraw with amount = 100
    share lastActor = actor
  }

  expect count(results, r => r.status == 200) == 1, "only one withdrawal may succeed"
}
```

`concurrently N { … }` starts N actors at the same moment. Each starts with a
copy of the session, and `actor` is its number. `sync "label"` holds every actor
at that point until all of them have arrived, which lines requests up as closely
as possible. After the block, `results` holds each actor's last response.

`share name = value` publishes a value that every actor, and every virtual user
of a load test, reads as `shared.name`.

## Load tests

```
load Checkout {
  users 50
  ramp 30s
  duration 5m
  think 200ms..1s
  seed checkout-load
  threshold p95 < 800ms
  threshold errors < 1%
  threshold rps > 40

  setup { run logIn }

  scenario {
    run createOrder with orderId = uuid("order")
    expect status == 201
    run getOrder with orderId = uuid("order")
  }
}
```

| Setting | |
|---|---|
| `users N`, `ramp 30s` | virtual users, started evenly over the ramp |
| `duration 5m` or `iterations 1000` | how long to run, or how many scenario runs in total |
| `think 200ms..1s` | a pause after each scenario run |
| `seed text` | repeatable data, see below |
| `threshold metric op value` | pass or fail on `p50`, `p90`, `p95`, `p99`, `avg`, `max` (durations), `errors`, `checks` (percentages), `rps` and `requests` |

`setup` runs once and every scenario run starts from a copy of its session.
Scenario runs see `vu` (the virtual user), `iteration` (that user's count) and
`run` (the number across the whole test). A request counts as failed when it
couldn't be sent or answered with 400 or more.

With a `seed`, every scenario run gets its own seed, `<seed>-<run>`. Random
values are repeatable, and keyed values tie requests together: `uuid("order")`
is the same id in `createOrder` and `getOrder` of one run, different in the next
run, and the same set of ids comes back when the test runs again. `person(key)`,
`address(key)` and `mock(schema, key)` follow the seed the same way.

```
stamp load . --json results.json
```

## Environments

A dimension is one axis your requests vary along: the environment they go to,
the region that serves them, the kind of account they use. Each one is a named
list of values, and variable sets say which values they apply to.

```
dimension env = test, staging, prod
dimension region = latam, mena, apac, dach
dimension userGroup = admin, member, guest

vars {
  host = localhost(8080)
  limit = 25
}

vars env=staging|prod {
  host = "api." + env + "." + region + ".example.com"
}

vars userGroup=guest {
  username = "guest"
  password = secret(getenv("GUEST_PASSWORD"))
  limit = 5
}
```

Choose one value per dimension. Every variable set whose conditions match
contributes its variables. Sets with fewer conditions are applied first, so a
more specific set overrides a broader one; sets with the same number of
conditions apply in the order they are written.

- `vars { }` applies everywhere.
- `name=a|b` matches either value.
- `name=*` is the same as leaving the dimension out.
- The selected dimension values are variables too: `env` above, which the
  second set builds its host from.

The first value of every dimension is the default. Choosing "any" for a
dimension means only sets that don't mention it apply.

Entries in a `vars` block are `name = expression`, or `@name = text`.

Dimensions and variable sets usually live in `environment.stamp`, but a request
file can declare its own before its first request; they are merged with the
workspace's.

## Working as a team

A workspace is a folder of text files, so it lives happily in git, next to the
code it talks to. Commit, pull and review requests with the tools you already
use; Stampdrill reloads whatever changes on disk.

`environment.local.stamp` holds personal variables: your tokens, a local host.
It is read after `environment.stamp`, so its values win for the same dimension
values. Values from `save` are written there, and when the workspace is a git
repository Stampdrill adds the file to `.gitignore` the first time it writes it.

```
# environment.local.stamp
vars {
  token = secret("my-own-token")
}
```

## Importing

**File › Import…** in the app, or `stamp import`, brings requests in from
other tools. Choose several files at once to bring a collection in with its
environments:

| From | Choose |
|---|---|
| Postman | a collection (format 2.0 or 2.1), environment or globals export |
| Insomnia | an export (JSON or YAML), including Insomnia 10 collections |
| Bruno | the collection folder, `.bru` or YAML (OpenCollection) |
| Browsers and proxies | a HAR file; only API calls are kept |
| curl | a file of curl commands, or `-` to read them from standard input |
| OpenAPI | an OpenAPI 3 or Swagger 2 document |

```
stamp import "Shop.postman_collection.json" staging.json production.json -o shop
pbpaste | stamp import - -o api
```

- Folders become `.stamp` files, and nested folders become folders.
- Environments become values of an `environment` dimension, and collection
  variables a `vars { }` block, in `environment.stamp`. Values it already has are
  kept.
- Tokens, passwords, API keys and cookies written out literally move to
  `environment.local.stamp` as `secret(…)`, so they stay out of git.
- `{{variable}}` names that aren't identifiers are renamed (`api-key` becomes
  `apiKey`), and placeholders such as `{{$guid}}` and `{{$randomEmail}}` become
  `uuid()` and `fake.email`.
- Auth becomes `@auth`: bearer, basic, API keys, and OAuth 2 client credentials
  and password grants.
- Common test lines, such as `pm.response.to.have.status(200)`, setting a
  variable from the response, and Bruno's assertions, become `>` statements.
  Other script lines are kept as comments.
- Insomnia's response tags become references to the other request, with
  `@needs`.

**File › Paste curl as Request** (⌥⌘V) adds the curl command on the clipboard to
the selected file, the way browsers' Copy as cURL writes it.

An OpenAPI document becomes a request file per tag. Each operation becomes a
request named after its `operationId`:

- the first server becomes `@baseUrl`, with server variables set to their defaults;
- path, header and required query parameters become variables, filled with the
  document's examples;
- security schemes become `@auth` lines (`bearer`, `jwt`, `basic`, `apikey`,
  or `oauth2` for client-credentials and password flows);
- request bodies use the document's examples, or sample data generated from the
  schema;
- the first documented `2xx` status becomes an assertion.

## Command line

`stampdrill`, the free command-line tool, reads the same workspaces as the app.

```
stamp run [path] [request…] [dimension=value…] [options]
stamp list [path]
stamp check [path]
stamp env [path] [dimension=value…]
stamp import file… [-o folder]
```

```
stamp run api/chat.stamp env=staging region=latam
stamp run api startAChat --var token=abc --verbose
stamp check .
stamp run media.stamp logo -o ~/Downloads/
```

`-o` saves the body of the last response, into a folder or to a file name.

`run` exits with 1 when a request fails or an assertion doesn't hold, and with 2
when a file has errors or the arguments are wrong. Values from `save` are written
to `environment.local.stamp` unless `--no-save` is given.
