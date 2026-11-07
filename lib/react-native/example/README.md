# Picknick example

Search screen and self-test for `react-native-picknick` on the iOS Simulator.

```sh
npm install
PICKNICK_DATA=/path/to/data ./scripts/copy-assets.sh   # folder with models/ and gazetteer/
(cd ios && pod install)
xcodebuild -workspace ios/PicknickExample.xcworkspace -scheme PicknickExample \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ios/build build
npm start -- --client-logs
./scripts/selftest.sh <simulator-id>   # prints PICKNICK_SELFTEST PASS or FAIL in Metro
```

`models/` holds `mobileclip_s2_image.mlpackage`, `mobileclip_s2_text.mlpackage` and `bpe_merges.txt`; `gazetteer/` holds the three GeoNames files.
