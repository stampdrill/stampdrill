---
name: stamp-files
description: Write, check and run Stampdrill .stamp files, the plain-text format for HTTP, GraphQL, WebSocket and MCP requests, response assertions, test plans, load tests, race-condition tests and multi-dimensional environments. Use when the user wants API requests, API tests, a test plan, a load or race-condition test, or environment variables written as .stamp (or .http) files; when a folder contains .stamp files or an environment.stamp; when converting curl commands, Postman, Insomnia or Bruno collections, HAR files or OpenAPI documents into request files; when running or debugging them with the stampdrill command line tool or in CI; or when the user mentions Stampdrill, the stampdrill or stamp command, or the Stampdrill Mac app.
---

# Writing .stamp files

A `.stamp` file is plain text: requests separated by `###`, each with a request
line, headers, an optional body and `>` script lines. A **workspace** is a folder
of them, usually with an `environment.stamp` at its root. The Stampdrill Mac app
and the `stamp` command-line tool read the same files.

Full language reference: https://stampdrill.com/language/

## Before writing

1. Look for an existing workspace: find `environment.stamp` and other `.stamp`
   files, and follow their names, variables and dimensions instead of inventing
   new ones.
2. Never write real secrets into a shared file. Tokens and passwords go into
   `environment.local.stamp` (kept out of git) or come from `getenv(...)`, and are
   wrapped in `secret(...)` so they are masked in output.

## A request

```
### Create a post
@name createPost
@timeout 10s
POST {{baseUrl}}/posts
Content-Type: application/json
Authorization: Bearer {{token}}

{ "title": "{{fake.sentence}}", "userId": {{userId}} }

> assert status == 201
> assert body.id != null, "the new post has no id"
> set postId = body.id
```

The order inside a request is fixed: variables and directives, the request
line, headers, **one empty line**, the body, then `>` script lines.

- The request line is `METHOD url`; a line starting with `http://`, `https://`
  or `{{` is a GET. Methods also include `GRAPHQL`, `WS`, `STUN`, `TURN` and `MCP`.
- `### Title` starts a request. Its name is `@name`, or the title in camelCase
  (`### Create a post` → `createPost`). Give requests that others depend on an
  explicit `@name`.
- A commented header (`# X-Debug: 1`) is kept as a disabled header.
- A body of a single `< ./path` line is read from that file.
- Lines starting with `#` or `//` are comments, except inside a body.

## Variables and expressions

```
@baseUrl = https://api.example.com/v1        # text, with {{ }} interpolation
let started = now()                           # an expression
fn page(n) = "?page=" + n + "&size=20"        # a function
```

- Declared before the first request: the whole file. Inside a request, before
  its request line: that request only.
- `{{ expression }}` works in URLs, headers, bodies and text variables.
- Expressions: `"text"`, `42`, `true`, `null`, `[1, 2]`, `{ key: value }`,
  `body.items[0].name`, `+ - * / %`, `== != < <= > >=`, `contains`, `matches`,
  `&& || !`, `a ?? b`, `cond ? a : b`, lambdas `x => x.id`.
- Equality is strict: `200 == "200"` is false.
- Useful functions: `uuid()`, `now()`, `timestamp()`, `randomInt(min, max)`,
  `json(value)`, `parseJson(text)`, `length`, `upper`, `lower`, `replace`,
  `split`, `join`, `base64`, `sha256`, `hmacSha256(key, message)`, `getenv(name)`,
  `secret(value)`, `map`, `filter`, `find`, `all`, `any`, `count`, `sum`,
  `min`, `max`, `sortBy`, `groupBy`, `unique`, `reduce`, `range`.
- Sample data: `fake.name`, `fake.email`, `fake.company`, `fake.price`,
  `fake.sentence` and more; `person(key)`, `address(key)` and
  `organization(key)` return related fields that stay the same for a key;
  `mock(readJson("./schema.json"), "key")` builds a value from a JSON Schema.
  Set `@seed = something` to make all of it repeatable.

## Directives

```
@needs logIn                    # run logIn first unless it already ran
@timeout 30s                    # also 1500ms, 2m
@no-redirect
@insecure                       # skip TLS verification
@auth bearer {{token}}
@auth basic {{user}} {{secret(password)}}
@auth apikey X-API-Key {{key}}
@auth oauth2 client_credentials token_url={{idp}}/token client_id=app client_secret={{secret(clientSecret)}}
```

`@auth` before the first request applies to the whole file.

## Response scripts

After the response arrives, `>` lines run with `status`, `headers` (lower-case
names), `body` (parsed JSON or text), `text`, `time` (ms) and `size`.

| Statement | Use |
|---|---|
| `assert condition` or `assert condition, "message"` | a check |
| `set name = value` | a variable for later requests in the session |
| `save name = value` | like `set`, and written to `environment.local.stamp` |
| `let name = value` | a variable for the rest of the script |
| `print value` | console output |

A request's response is available to later ones by name: `{{logIn.body.token}}`.
In `WS` requests the script can also `send value`, `receive 5s` (then
`message` and `data`), `wait 500ms` and `close`.

## MCP servers

`MCP http://localhost:3001/mcp` or `MCP stdio: node build/index.js` tests a Model
Context Protocol server. After the handshake the script has `server`, `tools`,
`toolNames`, `resources`, `resourceTemplates`, `prompts`, `promptNames` and
`notifications`, and these functions:

```
MCP stdio: node build/index.js

> assert toolNames contains "search"
> let found = call("search", { query: "stampdrill" })
> assert !found.isError
> assert found.text contains "stampdrill"
> assert read("docs://readme").text != ""
> assert getPrompt("summarize", { topic: "tests" }).messages.length > 0
> assert request("unknown/method").error.code == -32601
> notify("notifications/roots/list_changed")
```

- Results get `text`, the joined text content. JSON-RPC errors come back as
  `{ error }` (and `isError` for `call`) instead of failing the script.
- Server calls can't appear inside `=>` functions; call first with `let`.
- `@sampling reply …`, `@elicitation accept { … }` / `decline` / `cancel` and
  `@roots uri, uri` answer requests the server sends to the client.
- `send` and `receive` exchange raw JSON-RPC messages and notifications.

## Environments with dimensions

A dimension is one axis requests vary along: the environment they go to, the
region serving them, the kind of account they run as. `environment.stamp` names
the axes and their values, and each `vars` block says which values it applies
to. More specific blocks win.

```
dimension env = test, staging, prod
dimension region = latam, mena, apac, dach
dimension userGroup = admin, member, guest

vars {
  baseUrl = localhost(8080)
}

vars env=staging|prod {
  baseUrl = "https://api." + env + "." + region + ".example.com"
}

vars userGroup=guest {
  username = "guest"
  password = secret(getenv("GUEST_PASSWORD"))
}
```

- Prefer a dimension over copying variables per environment.
- `name=a|b` matches either value; `name=*` or leaving it out matches any.
- The selected values are variables too, so `{{env}}` works in a request.
- Personal values go in `environment.local.stamp` with the same syntax.

## Test plans and load tests

Plans and load tests are written **before the first request** of a file.

```
plan Checkout {
  matrix env = staging|prod
  retry 2 every 500ms
  setup { run logIn }

  step "Browse" {
    run listProducts with limit = 5
    expect status == 200
    set productId = body[0].id
  }

  concurrently 5 {
    sync "go"
    run redeemCoupon with code = "WELCOME"
  }
  expect count(results, r => r.status == 200) == 1
}

load Browse {
  users 20
  ramp 10s
  duration 1m
  seed browse-load
  threshold p95 < 800ms
  threshold errors < 1%
  scenario {
    run listProducts
    expect status == 200
  }
}
```

Plan statements: `run name with a = expr`, `expect`, `set`, `let`, `print`,
`wait`, `step "…" { }`, `repeat 3 { }`, `for each x in list { }`,
`if … { } else { }`, `concurrently N { }` with `sync "label"` and
`share name = value`. Settings: `matrix`, `data ./file.csv`, `parallel`,
`retry`, `timeout`, `tags`.

## Running them from a terminal

`brew install stampdrill/tap/stampdrill` installs the free command-line tool under two
names, `stampdrill` and the shorter `stamp`. They are the same program and either can be used. It reads exactly the files the Mac
app reads. **Always `check` what you wrote**; only send requests to systems the
user has said you may call.

```bash
stamp check .                      # parse errors, unknown @needs; sends nothing
stamp list .                       # every request, grouped by file
stamp run api/orders.stamp         # a file
stamp run api/orders.stamp listOrders --no-save
stamp run . env=staging region=latam   # dimension values as arguments
stamp env . env=staging            # what those dimensions resolve to
stamp test . --tags smoke --junit reports/junit.xml
stamp load . --json reports/load.json
stamp import collection.json env.json -o api
```

Options worth knowing:

| Option | Use |
|---|---|
| `-v, --var name=value` | Override a variable without editing files |
| `--no-save` | Don't let `save` write to `environment.local.stamp` |
| `--verbose` / `-q, --quiet` | Headers and bodies / failures only |
| `--show-secrets` | Unmask `secret(...)` values; avoid in shared logs |
| `-o, --output path` | Write the last response body to a file |
| `--junit path` | JUnit XML for CI |
| `--html path` | One HTML file: parse the markup, or open it in a browser |
| `--json path` | The whole run as JSON |
| `--no-color` | Plain output, better for parsing |

Exit codes: **0** all good, **1** a check or threshold failed, **2** a file has
errors. `STAMPDRILL_NO_BANNER=1` and `CI=1` suppress the banner. The Linux builds
are fully static, so CI needs nothing installed:

```yaml
- run: |
    curl -sL https://github.com/stampdrill/stampdrill/releases/latest/download/stampdrill-linux-x86_64.tar.gz | tar xz
    ./stamp test api --junit reports/junit.xml
```

## Running them through MCP

`stamp mcp [path]` serves a workspace over the Model Context Protocol on stdio, which is useful when the
agent cannot run shell commands. Register it once:

```json
{ "mcpServers": { "stampdrill": { "command": "stamp", "args": ["mcp", "."] } } }
```

Tools: `list_requests`, `check`, `run_request` (with `dimensions` and `variables`), `run_plan`, `run_load` and
`show_environment`. Keep writing the files with ordinary file tools; use these only to run them.

## In the Mac app

The app opens a folder of `.stamp` files and writes changes straight back to
them, so a workspace can be edited in the app, in an editor and by an agent in
the same session.

- **Open Example Workspace** on the welcome screen installs a working workspace
  that calls public test APIs, the quickest way to see the format run.
- The toolbar switches between a **form view** and the **source** of the same
  file, and its dimension menus pick the values a request runs with.
- **⌘↩** sends the selected request; the response, its headers, timings and the
  assertions that ran appear below it.
- The inspector on the right shows the variables in effect and where they come
  from. Values wrapped in `secret(...)` stay blurred until you ask for them.
- An `MCP` request gets an **inspector** listing the server's tools, resources
  and prompts, with a form for calling a tool and saving the call as a test.
- **File ▸ Import…** takes Postman, Insomnia, Bruno, HAR, curl or OpenAPI, and
  **⌥⌘V** pastes a copied curl command in as a request.

Tell the user to keep `environment.local.stamp` out of git; the app writes
personal values and anything from `save` there.

## Common mistakes

- No empty line between headers and body, so the body is read as headers.
- `plan` or `load` blocks placed after a request.
- Script lines without `>`, or placed before the body.
- Quoting numbers in JSON bodies that should stay numbers: write
  `"userId": {{userId}}`, not `"userId": "{{userId}}"`, when the API expects a number.
- Comparing with `==` across types (`status == "200"`).
- Hard-coding hosts in every request instead of one variable or dimension.
- Real credentials in `environment.stamp`.

## Converting from other formats

Prefer `stamp import` when it's installed: it reads Postman collections and
environments, Insomnia exports, Bruno folders (`.bru` or YAML), HAR files, curl
commands (`-` reads standard input) and OpenAPI documents, merges environments
into `environment.stamp` and moves literal credentials to
`environment.local.stamp`. Then review the result: notes in `#` comments mark
scripts and auth it couldn't convert. By hand:

- **curl**: method from `-X` (or `POST` when there is `-d`), each `-H` becomes a
  header, `-d`/`--data-raw` becomes the body, `-u user:pass` becomes
  `@auth basic`.
- **Postman**: folders become files, `{{variable}}` stays as is (renamed when it
  isn't an identifier), environments become `vars` blocks under one dimension
  such as `environment`, and test scripts become `>` assertions.
