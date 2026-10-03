# Contributing

Bug reports, format proposals and fixes are welcome.

## Reporting

Open an issue with the `.stamp` file that shows the problem, what you expected
and what happened. A file that reproduces it is worth more than a description.

## Building

Swift 6.1 or later, on macOS or Linux:

```bash
swift build
swift test
swift run stamp check "Examples/Public APIs"
```

## Pull requests

- One change per pull request.
- Add a test. `Tests/StampTests` covers the language, `Tests/StampdrillCoreTests`
  covers workspaces, runners and importers.
- Match the surrounding code: no abbreviations in names, comments that say why
  rather than what, and no comment at all when the code is already clear.
- Run `swift test` before pushing. CI runs it on macOS and Linux.

## Changing the language

The format is used by files people keep for years, so additions have to be
backwards compatible. Open an issue describing the problem before writing the
parser change, the discussion is usually shorter than the patch.

## Licensing

Code under `Sources/` and `Tests/` is MPL-2.0; documentation, examples, the
agent skill and the editor grammar are MIT. By contributing you agree your
contribution is published under the licence of the area you changed.
