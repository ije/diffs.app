# diffs.app

This is a macOS native app using swiftUI. After changing code, run `xcodebuild -project "diffs.xcodeproj" -scheme "diffs" -configuration Debug -sdk macosx build` to ensure the app is built correctly.

## 3rd-party Libraries

- `vendor/oniguruma`: Oniguruma is a modern and flexible regular expressions library. It encompasses features from different regular expression implementations that traditionally exist in different languages. Character encoding can be specified per regular expression object.
