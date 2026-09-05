# MarathiMass · native iPhone app

The same one-button live translator as `../live-translation`, but as a real iOS
app written in SwiftUI. Same pipeline: microphone → Azure Speech translation →
Marathi text on screen + Marathi voice in the earphones.

## Why a native app instead of the website?

| | Website (`../live-translation`) | This iPhone app |
|---|---|---|
| Install on parents' phones | Open a link, "Add to Home Screen". Done. | Needs a Mac with Xcode **and** an Apple Developer account ($99/yr) for TestFlight, otherwise the app expires after 7 days. |
| Keeps working with the screen locked | No, iOS pauses the browser mic. Screen must stay on. | **Yes.** Background audio mode keeps listening with the phone locked in a pocket. |
| Needs a server | Yes (tiny token server). | Optional. The Azure key can be pasted into Settings directly. |
| Updates | Redeploy, everyone gets it. | Rebuild and reinstall / TestFlight. |

Honest recommendation: start with the website. Move to this app if the
"screen must stay on" limitation turns out to be a nuisance in church.

## What you need

* A Mac with Xcode 15 or newer (free from the App Store).
* Homebrew tools: `brew install xcodegen cocoapods`
* An Azure "Speech" resource: key + region (see the web app README, step 1).
* To put it on your parents' phones for a 5-6 month stay you need an
  **Apple Developer Program** membership ($99/year) so you can distribute via
  TestFlight (builds last 90 days, re-upload to extend). With only a free Apple
  ID, Xcode can install the app directly onto a phone plugged into the Mac, but
  it stops launching after **7 days** and up to 3 apps/devices. Fine for testing,
  not for a season of Sundays.

## Build

```bash
cd ios-app
xcodegen            # generates MarathiMass.xcodeproj from project.yml
pod install         # pulls MicrosoftCognitiveServicesSpeech-iOS 1.51.x
open MarathiMass.xcworkspace
```

In Xcode:
1. Select the `MarathiMass` target → **Signing & Capabilities** → pick your Team.
   Change the bundle identifier (`com.example.marathimass`) to something unique.
2. Plug in an iPhone, choose it as the run destination, press ▶.
3. On first launch the app opens Settings. Paste the Azure key and region
   (Option A), or the address of your hosted web app plus its PIN (Option B).
4. Put earphones in, tap **सुरू करा / Start**, speak some English.

If you prefer not to use XcodeGen: create a new "App" project in Xcode named
`MarathiMass` (SwiftUI, Swift), delete its `ContentView.swift`, drag every file
from `MarathiMass/` into the project, add the `Podfile` and run `pod install`,
and add the `NSMicrophoneUsageDescription` and `UIBackgroundModes: audio` keys
to Info.plist (they are listed in `project.yml`).

## Files

```
ios-app/
├── project.yml                    XcodeGen spec (bundle id, Info.plist keys, iOS 16+)
├── Podfile                        Microsoft Speech SDK for iOS
└── MarathiMass/
    ├── MarathiMassApp.swift       app entry
    ├── ContentView.swift          the one-button screen
    ├── SettingsView.swift         voice, text size, Azure key / server
    ├── AppSettings.swift          persisted settings
    ├── Credentials.swift          key-on-phone or token-from-server
    ├── TranslationService.swift   mic → Azure translation → text + audio, reconnect, token refresh
    ├── AudioPlayerQueue.swift     AVAudioEngine queue that plays each Marathi utterance in order
    └── Assets.xcassets            app icon
```

## Notes and caveats

* This code was written against the documented Speech SDK 1.51 Objective-C/Swift
  API but was **not compiled** here (Xcode only runs on macOS). Expect at most a
  couple of trivial fixes on first build. If the two `setPropertyTo(…, by:)`
  lines in `TranslationService.swift` do not compile on your SDK version, delete
  them; they only tune silence timeouts.
* Distribution reality check is above: TestFlight needs the paid developer
  program. The website has no such hurdle.
* Audio session is `.playAndRecord` with `.allowBluetoothA2DP`, so AirPods stay
  on the high-quality output profile and the **phone's own mic** does the
  listening. That is what you want in a pew: the phone hears the priest, the
  earbuds only play.
* Marathi neural voices: `mr-IN-AarohiNeural` (female), `mr-IN-ManoharNeural` (male).
* Cost is the same as the web app: roughly $2.50 per audio hour on the standard
  tier, 5 free hours per month on F0.
