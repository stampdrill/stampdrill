# Security

## Reporting a vulnerability

Email **privacy@siamand.cc** with the details and a way to reproduce it. Please
don't open a public issue for a vulnerability.

You'll get an acknowledgement within a few days, and a fix or an explanation
before any public disclosure.

## What this project touches

`stampdrill` sends the requests in your files and nothing else. It makes no
calls of its own: no update check, no telemetry, no analytics.

Values wrapped in `secret(...)` are masked in output and in reports. They are
*masked*, not encrypted, a `.stamp` file is plain text, so real credentials
belong in `environment.local.stamp` (kept out of git) or in `getenv(...)`.

Requests run scripts written in the files themselves. Treat a `.stamp` file from
someone else the way you would treat any script: read it before you run it.
