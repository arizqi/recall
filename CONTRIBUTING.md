# Contributing to Recall

Thank you for helping improve Recall.

## Before you start

- Search existing issues before opening a new one.
- Keep changes focused. A parser change should include a synthetic fixture that
  covers the storage-format behavior it relies on.
- Never commit real conversation exports, transcripts, credentials, usernames,
  home-directory paths, or generated indexes. Reduce bug reports to synthetic
  data before attaching them.

## Development setup

Recall requires macOS 14 or later, Xcode 15 or later, and XcodeGen.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Recall.xcodeproj -scheme Recall \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Ollama is needed for interactive vector search, but the test suite does not
require a running Ollama server.

When `project.yml` changes, run `xcodegen generate` and commit the regenerated
`Recall.xcodeproj` files with it.

## Pull requests

Before opening a pull request:

1. Run the full test command above.
2. Confirm `git status` contains no local data or build output.
3. Explain the observable behavior changed and how it was tested.
4. Call out any new filesystem access, network access, or privacy implications.

By contributing, you agree that your contributions will be licensed under the
MIT License.
