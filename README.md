# Strongroom

A native iOS/iPadOS (SwiftUI) vault for photos, videos, files and notes. Draw a pattern to open it.
Everything is encrypted on the device; there's no account and no server that can read anything.

## Features

| | |
|---|---|
| **Pattern unlock** | 5×5 grid, at least 6 dots, at least one change of direction. Crossing a dot selects it. |
| **Many hidden vaults** | Each pattern opens its own vault. There's no vault list, and file names on disk don't say which vault owns them. |
| **Recovery phrase** | 9 BIP-39 words (or your own phrase) open the vault without the pattern, on this phone or a new one. |
| **Duress vault** | Opening a vault marked as duress deletes every other vault from the device first. iCloud backups stay. |
| **Encrypted iCloud backup & sync** | Private CloudKit database, encrypted before upload. Restore with the phrase; use one vault on iPhone and iPad. |
| **Secure sharing** | Share a snapshot of a vault with a separate 9-word phrase, with an open limit, an expiry and a no-export mode. Revoke at any time. |
| **Secure camera** | Photos and videos go straight into the vault, never the camera roll. |
| **Library** | Nested folders with a custom order, day sections, search, multi-select, move, export, notes, any file type with QuickLook. |
| **Optimized storage** | Optional HEIC/HEVC re-encoding (only when smaller; drops location data), or keep originals. |
| **Disguise icons** | Calculator, Printer, Notes, Weather, Compass, Clock, Scanner. Every icon opens the pattern screen. |
| **Hygiene** | Locks when backgrounded, privacy cover in the app switcher, decrypted temporary files wiped on lock, escalating lockout after wrong patterns. |

## Run it

1. On a Mac with Xcode 16+: `brew install xcodegen`, then run `xcodegen` in this folder.
2. In `project.yml`, change `bundleIdPrefix` and `PRODUCT_BUNDLE_IDENTIFIER`. Then open `Strongroom.xcodeproj` and pick your team.
3. **iCloud (backup, sync, sharing)** needs a paid Apple Developer account. Xcode's automatic signing creates the container `iCloud.<your bundle id>` from the entitlements file. Builds run from Xcode use CloudKit's *Development* environment, where the record types (`VaultManifest`, `VaultBlob`, `VaultShare`, `VaultShareBlob`, `VaultShareOpen`) are created on first use. Before a TestFlight or App Store build, deploy the schema to Production in the CloudKit Console. No indexes are needed: everything is fetched by record ID.
   *No paid account?* Set `CLOUDKIT_ENABLED: "NO"` and delete the `CODE_SIGN_ENTITLEMENTS` line in `project.yml`. Everything else works; iCloud features show as unavailable.
4. Press ⌘U to run the test suite, then run on your device.

CI (`.github/workflows/ios.yml`) generates the project and runs every test on an iOS simulator for each push to a pull request.

## Cryptography

All primitives come from CryptoKit (AES-256-GCM, HKDF-SHA256, HMAC-SHA256) plus CommonCrypto PBKDF2-SHA256.

```
deviceSalt   = 32 random bytes, Keychain, WhenUnlockedThisDeviceOnly (never leaves the phone)

pattern      → PBKDF2("pattern:v1:"+dots, deviceSalt, 600k) → HKDF → wrapKey, locatorKey
phrase       → PBKDF2("recovery:v1:"+words, fixed salt, 600k) → HKDF → wrapKey, locatorKey
header name  = HMAC(locatorKey, label)            opaque file name, found only with the secret
header       = AES-GCM(wrapKey, pad1024{masterKey, indexName})

masterKey    → HKDF "index"  → index key   (index = AES-GCM(pad4096(JSON)))
             → HKDF "backup" → backup key  (cloud manifest payload, blob record names)
item         = own random 256-bit key; contents in 1 MB AES-GCM chunks
               nonce = prefix‖counter, AAD = counter‖isFinal (no reordering, truncation or appending)
thumbnail    = AES-GCM(item key)

share phrase → PBKDF2("share:v1:"+words, fixed salt, 200k) → share key, locator key
```

Every file in the vault folder has a random-looking 32-hex-character name, whether it's a header, an index, a thumbnail or a file.

## Security model and limits

- **What's trusted:** the app, iOS, and an unlocked phone. Anyone who sees you draw the pattern, or holds your recovery phrase, can open the vault.
- **Patterns are weak secrets** (roughly 20–30 bits). Strength comes from the device salt, which keeps guessing on this phone, plus 600k PBKDF2 iterations and the lockout. A copied storage folder can't be attacked off the device.
- **Deniability is partial:** someone examining the phone can't see which vault a file belongs to or list vaults, but can estimate how many exist from the headers.
- **Duress** deletes from the device, not from iCloud. Overwritten flash blocks may still be recoverable forensically, though they stay encrypted.
- **Share limits** (open count, expiry, no-export) are enforced by the app. iOS can't block screenshots, so the app hides content during screen recording and warns after a screenshot. Someone determined could still photograph the screen.
- **Losing the pattern and the phrase** (or the phrase and the backup) means the data is gone. There's no backdoor.
- **No independent audit.** This is a personal project: review it before trusting it with anything critical.

## Layout

```
Strongroom/
  Crypto/   KDF, Box (AES-GCM records), ChunkedCipher (files), Keychain, RecoveryPhrase
  Vault/    Pattern, BlobStorage, VaultIndex, Vault (actor), Session (app state), ImportPipeline, TempFiles
  Cloud/    BackupStore + CloudKit, CloudSync (backup/sync/restore), VaultMerge, Sharing
  UI/       Unlock, folders/grid, media pager, notes, settings, recovery, sharing, camera, app icons
StrongroomTests/  crypto vectors, vault, recovery, sync (in-memory CloudKit stand-in), merge, sharing
```
