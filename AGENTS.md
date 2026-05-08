# diffs

## build

This is a macOS native app using swiftUI. After changing code, run `xcodebuild -project "diffs.xcodeproj" -scheme "diffs" -configuration Debug -sdk macosx build` to ensure the app is built correctly.

## ported code

- `vscode/vscode-textmate` -> `diffs/TextMate`: An interpreter for grammar files as defined by TextMate. TextMate grammars use the oniguruma dialect (https://github.com/kkos/oniguruma). Supports loading grammar files from JSON or PLIST format. This library is used in VS Code. Cross - grammar injections are currently not supported.
- `vscode/vscode-oniguruma` -> `diffs/Vendor/onig_bridge.h`: Oniguruma bindings for VS Code. This library is used in VS Code and is not intended to grow to have general Oniguruma WASM bindings.


## 3rd party libraries

- `/vendor/oniguruma`: Oniguruma is a modern and flexible regular expressions library. It encompasses features from different regular expression implementations that traditionally exist in different languages. Character encoding can be specified per regular expression object.
