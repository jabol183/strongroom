# Strongroom

A native iOS (SwiftUI) pattern-locked, encrypted photo vault, built for personal use.
No account and no server: everything is encrypted on the device.

## Run it

1. On a Mac with Xcode 16+: `brew install xcodegen`, then run `xcodegen` in this folder.
2. Open `Strongroom.xcodeproj`, choose your team under Signing & Capabilities, and change the bundle ID.
3. Run the tests with ⌘U (crypto vectors, tamper/truncation detection, vault isolation), then run the app on your iPhone.

A paid Apple Developer account keeps the app installed. With a free account it expires after 7 days.

## What step 1 includes

- 5×5 pattern unlock: at least 6 dots and at least one change of direction. Crossing a dot selects it.
- Drawing an unknown pattern asks you to draw it again, then creates a new, empty vault. There's no vault list.
- Photo import from the photo library. Each photo is encrypted on import and gets a thumbnail.
- Grid, full-screen viewer and delete.
- Auto-lock when the app goes to the background, and a privacy cover in the app switcher.
- Escalating lockout after 5 consecutive unknown patterns (30 s, doubling, capped at 1 h).

## Key hierarchy

```
deviceSalt  = 32 random bytes in the Keychain (WhenUnlockedThisDeviceOnly)
patternIKM  = PBKDF2-SHA256("pattern:v1:" + "0-6-12-…", deviceSalt, 600,000)
wrapKey     = HKDF(patternIKM, "strongroom.wrap.v1")
locatorKey  = HKDF(patternIKM, "strongroom.locator.v1")
headerName  = HMAC(locatorKey, "header")[0..16]   → opaque file name of the vault header
header      = AES-GCM(wrapKey, pad1024({ masterKey, indexName }))
indexKey    = HKDF(masterKey, "strongroom.index.v1")
index       = AES-GCM(indexKey, pad4096(JSON items))   — each item has its own random fileKey
photo blob  = chunked AES-GCM (1 MB chunks, nonce = prefix‖counter, AAD = counter‖isFinal)
thumbnail   = AES-GCM(fileKey, jpeg)
```

Every file in `Application Support/Store` has a random-looking 32-hex-character name. Headers, indexes, thumbnails and photos look the same on disk, so the folder doesn't show which file belongs to which vault.

## Known limits (so far)

- **Recovery:** if the device salt is lost (new phone, device erased), every vault is gone. The recovery phrase and CloudKit backup in steps 3–4 fix this.
- **Pattern strength:** patterns carry little entropy. What protects the vault is the device salt, which keeps attacks off the phone, plus PBKDF2 and the lockout on the phone. A thief who has your unlocked phone and unlimited time is outside this design.
- **Memory:** keys are dropped when the app locks, and CryptoKit zeroes `SymmetricKey` storage when it's freed. Decrypted photo bytes stay in memory until SwiftUI releases them.
- **Originals:** imported originals stay in the Photos app until you delete them. A "delete after import" option needs PhotoKit access (step 2).

## Roadmap

1. ✅ Pattern, keys, encrypted photo store
2. Folders, video (`ChunkedCipher.encryptFile`/`decryptFile` are ready), secure camera, delete-after-import
3. Nine-word recovery phrase (second wrap of the master key), duress pattern
4. CloudKit encrypted backup and device sync, sharing via phrase, alternate "disguise" app icons
