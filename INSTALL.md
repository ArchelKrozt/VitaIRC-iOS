# Installing VitaIRC on iPhone or iPad

Apple only lets apps from outside the App Store be installed when they are signed with **your own
Apple ID**. The release has an unsigned `VitaIRC.ipa`; one of these tools signs it with your account
and installs it. Your Apple ID and password go only to Apple.

| | Free Apple ID | Apple Developer account (99 USD/year) |
|---|---|---|
| How long the app works | 7 days, then it must be refreshed | 1 year |
| Refresh | AltStore/SideStore do it by themselves | — |

## Option A: AltStore (recommended, renews by itself)

1. On a Mac or PC, install **AltServer** from <https://altstore.io> (on a Mac it lives in the menu bar).
2. Connect the iPhone with a cable, trust the computer, and in AltServer choose
   **Install AltStore → your iPhone**. Sign in with your Apple ID.
3. On the iPhone: **Settings → General → VPN & Device Management →** your Apple ID → **Trust**.
   On iOS 16 or newer also turn on **Settings → Privacy & Security → Developer Mode** (the iPhone restarts).
4. On the iPhone, open Safari, download `VitaIRC.ipa` from the
   [latest release](https://github.com/ArchelKrozt/VitaIRC-iOS/releases/latest),
   tap **Share → AltStore** (or in AltStore: **My Apps → +** and choose the file).
5. VitaIRC appears on the home screen. AltStore renews it every few days while the computer with
   AltServer is on the same Wi-Fi (or open AltStore and tap **Refresh All**).

**SideStore** (<https://sidestore.io>) works the same way but renews from the iPhone itself, without
the computer, after the first setup.

## Option B: Sideloadly (simple, renew it by hand every 7 days)

1. Install **Sideloadly** (<https://sideloadly.io>) on a Mac or PC and connect the iPhone with a cable.
2. Drag `VitaIRC.ipa` into Sideloadly, type your Apple ID and press **Start**.
3. On the iPhone: **Settings → General → VPN & Device Management →** your Apple ID → **Trust**
   (and Developer Mode on iOS 16 or newer, see above).
4. After 7 days the app stops opening: repeat step 2 (your settings and history stay).

## Option C: Xcode (for developers)

```sh
brew install xcodegen
xcodegen generate
open VitaIRC.xcodeproj
```

In Xcode choose your team under **Signing & Capabilities**, connect the iPhone and press **Run**.

## Updates

VitaIRC checks GitHub once a day and tells you when there is a new version. iOS doesn't let it
install by itself: download the new `VitaIRC.ipa` and install it the same way (AltStore: **+**;
Sideloadly: drag it again). It installs over the old one and keeps your servers, settings and history.

## Your settings and the Vita

VitaIRC's files are in the **Files** app → **On My iPhone → VitaIRC**: `config.ini` (the same file as
on the Vita and Android: copy yours there to bring your servers), the chat logs and your favorites.
