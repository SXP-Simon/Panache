# Flutter assets in the same release

`Flutter Release Assets` follows Semantic Release on `custom-base` and consumes that exact run's `release-result`. It adds Flutter packages to the existing release without creating another tag or changing source versions.

## Pinned source and checks

The first automatic build resolves a full `flutter` commit SHA. The latest matching push or manually dispatched run for each of `Flutter UI`, `Rust 后端` and `Flutter Mobile` must pass for that exact SHA, `flutter` branch and repository. A newer pending or failed run blocks an older success; pull-request and fork runs cannot authorize a release build.

Quality workflows keep their path filters. If documentation or build-script changes did not trigger one, manually run the missing workflow on `flutter`, verify its exact SHA matches the intended source, and retry asset packaging after it passes.

Before building, the workflow uploads an immutable `Flutter-source.json` asset containing the release version, deterministic build number, Flutter SHA and successful run IDs. Builds check out that SHA; controller scripts use the workflow's own SHA. A retry cannot replace the pinned source. Older source lacking explicit version or formal signing support fails clearly.

The release version is passed through desktop build flags and `HANDWRITING_BUILD_VERSION` so the package, bundled Rust API and displayed version agree. Build numbers are `major × 1,000,000 + minor × 1,000 + patch`, with minor/patch below 1000 and an Android-compatible positive result. Only stable `vX.Y.Z` tags are supported.

Pending checks for the fixed SHA are polled every 30 seconds with a shared 30-minute limit. Missing runs receive a 90-second scheduling grace period. Failed or cancelled checks reject immediately. After timeout, retry with that same SHA; waiting never resolves the branch again or silently picks another source.

## Packages and signing

Packages use a `Flutter-Panache-<version>-` prefix with `windows-x64.zip`, `linux-x64.tar.gz`, `macos-arm64.zip`, and, when formally signed, `android-arm64-v8a.apk` (recommended for phones) and `android-x86_64.apk` (x86_64 emulators/devices). Each archive has a JSON provenance asset containing its source SHA, version and SHA-256. All required packages and packaged-backend version checks must pass before the retry-capable upload step.

Android requires all four repository secrets: `HANDWRITING_ANDROID_KEYSTORE_BASE64`, `HANDWRITING_ANDROID_STORE_PASSWORD`, `HANDWRITING_ANDROID_KEY_ALIAS`, and `HANDWRITING_ANDROID_KEY_PASSWORD`. Without all four, APK publishing is explicitly skipped in the source manifest and job summary. A temporary signing file is removed after use; `apksigner verify` must pass and Android Debug certificates are rejected. A debug-signed local APK is not a release substitute.

macOS remains ad-hoc signed; see [Desktop App](desktop.md). No unsigned or unprovisioned iOS IPA is distributed.

## Manual retries

Run **Flutter Release Assets** with an existing `tag`. A first build for a historical release also requires `flutter_ref`, a complete 40-character SHA with all three successful checks. If the release already has `Flutter-source.json`, omit the SHA or provide the same pinned value; changing it is rejected.

If the first run failed before creating its manifest, use Run workflow with the original SHA from its waiting logs; an automatic retry cannot resolve a newer branch.

Retries recheck the same source and use the same build number. Adding signing secrets later allows the formally signed APK to be added from that source, without selecting a newer branch commit.

The manifest `product_name` fixes the download package brand. Historical manifests without this field keep the original `HandwritingWeb` prefix, so retries do not rename existing release assets.

Split Android APKs retain Flutter ABI version-code offsets: +2000 for arm64-v8a and +4000 for x86_64, in addition to the base `build_number`. Publishing verifies the actual package ID, version name, and version code with `aapt2`, then records `android_version_code` in each APK JSON. Clients support older metadata by applying the same offsets; dropping them could turn a new release into a system-level downgrade.
