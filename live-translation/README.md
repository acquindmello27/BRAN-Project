# थेट भाषांतर · Live Translation (English → Marathi)

A one-button web app for listening to an English Mass in Marathi.

Put earphones in, open the page, tap **सुरू करा / Start**. Everything the phone's
microphone hears in English is spoken back in Marathi a sentence or two later,
and the Marathi text is also shown on screen in large type. Tap **थांबवा / Stop**
to stop. That is the whole interface.

## How it works

```
phone mic ──► Azure Speech "speech translation" (websocket) ──► Marathi text + Marathi voice ──► earphones
```

* **One vendor, one stream.** Azure AI Speech does English recognition, translation
  to Marathi, and Marathi neural text-to-speech (`mr-IN-AarohiNeural` /
  `mr-IN-ManoharNeural`) in a single connection. Latency is roughly "one phrase
  behind" the priest: the service waits for a short pause, finalizes the phrase,
  translates it and speaks it.
* **Nothing to install on the phone.** It is a normal web page; add it to the home
  screen for an app icon. Works in Safari (iPhone) and Chrome (Android).
* **Tiny server.** `server.js` is ~120 lines of plain Node with **zero npm
  dependencies**. It serves the page and hands the phone a 10-minute Azure token so
  the real key never leaves the server.
* Why not Meta's Muse? Muse Voice Transcribe (Sept 2026) only transcribes; it does
  not translate or speak. Meta's older Seamless models can translate *text* into
  Marathi but cannot produce Marathi *speech*, and self-hosting them is anything but
  lightweight. Azure is the simplest end-to-end option that actually speaks Marathi.

## Cost

Azure Speech translation is billed per hour of audio (about $2.50/hour on the
standard tier at the time of writing; the free F0 tier includes 5 hours/month).
A weekly one-hour Mass for six months is roughly 26 hours, so expect **well under
$100 per year**, and possibly $0 if you stay inside the free tier.

## Setup (once, ~15 minutes)

### 1. Create an Azure Speech resource
1. Sign in at <https://portal.azure.com> (free account is fine).
2. **Create a resource → "Speech"** (Azure AI services). Pick a region close to you
   (e.g. `eastus`) and the **F0 (free)** or **S0** pricing tier.
3. Open the resource → **Keys and Endpoint**. Copy **KEY 1** and the **Region**.

### 2. Run the server
Requires Node.js 18 or newer.

```bash
cd live-translation
cp .env.example .env        # then paste your key + region into .env
npm start                   # http://localhost:3000
```

There is no `npm install` step.

### 3. Put it on the internet (so the phones can reach it at church)
The phone needs HTTPS to use the microphone, so run the server somewhere public.
Any Node host works. Two easy free-tier options:

* **Render / Railway / Fly.io**: point them at this repo, set the root directory to
  `live-translation`, start command `npm start`, and add `AZURE_SPEECH_KEY`,
  `AZURE_SPEECH_REGION` (and `APP_PIN`, see below) as environment variables.
  They give you an `https://...` URL automatically.
* **Your own box + Cloudflare Tunnel / Tailscale Funnel** if you already run a
  home server.

Set **`APP_PIN`** (any short number) when the server is public. The app asks for
it once under ⚙ and remembers it; without it anyone who finds the URL could run
up your Azure bill.

### 4. On your parents' phones
1. Open the URL in Safari/Chrome, allow the microphone when asked.
2. **Share → Add to Home Screen** so it has an icon like a real app.
3. Optionally open ⚙ once to pick the voice (Aarohi = female, Manohar = male) and
   a larger text size. Settings are saved on the phone.

## Tips for church

* **Microphone placement matters most.** The phone has to hear the priest clearly.
  Keep it out of the pocket: on the pew, in a hand, or in a shirt pocket facing
  forward. Sitting nearer the front and away from the choir helps a lot.
* **Earphones with a built-in mic** (wired EarPods, AirPods): the phone may use the
  earphone mic instead of its own. That still works; it just needs to be
  uncovered.
* **Two people, one phone**: iPhone can share audio to two pairs of AirPods
  (Control Center → AirPlay → Share Audio); or use a cheap headphone splitter.
  Otherwise each person uses their own phone with the same URL.
* **Keep the screen on.** The app requests a screen wake lock, but if the phone
  locks, iOS will pause the microphone. Turn brightness down instead of locking.
* **Silence is fine.** Hymns, pauses and the procession do not disconnect the app.
  If the network blips it reconnects on its own; if it gives up it says
  "जोडणी तुटली / Connection lost", just tap Start again.
* The Marathi text on screen is useful when the audio gets behind, and for anyone
  who prefers reading.

## Settings (⚙)

| Setting | What it does |
|---|---|
| Marathi voice | Aarohi (female) or Manohar (male) |
| Speech engine | **Fast**: Azure speaks the translation in the same stream (default, lowest latency). **Separate text-to-speech**: translation returns text, a second call speaks it. Slightly slower but lets you change the speaking speed. |
| Speaking speed | Only for the separate engine. "Faster" helps catch up during a fast speaker. |
| Text size | On-screen Marathi text size |
| Access PIN | Matches `APP_PIN` on the server |

## Files

```
live-translation/
├── server.js               static files + /api/token (Azure token minting), no dependencies
├── package.json            `npm start`
├── .env.example            copy to .env
└── public/
    ├── index.html          the one-button UI
    ├── app.js              mic → Azure translation → Web Audio playback queue
    ├── manifest.webmanifest, icon.svg, apple-touch-icon.png
    └── vendor/speech-sdk-1.51.0.min.js   Microsoft Speech SDK for the browser (MIT)
```

## Troubleshooting

* **"Open ⚙ and enter the access PIN"**: the server has `APP_PIN` set; type it in Settings.
* **"Microphone permission denied"**: iPhone Settings → Safari → Microphone → Allow,
  or Android site settings. Reload the page.
* **Starts but never speaks**: check the server log; a 401/403 from Azure means the
  key or region in `.env` is wrong. Also make sure the phone volume is up and the
  ringer switch is not muting media.
* **Audio lags far behind**: move the phone closer to the speaker (fewer
  mis-recognitions means shorter translations), or switch to the separate engine
  and choose "Faster".
* **Home-screen app has no microphone on an older iPhone**: open the same URL in
  Safari itself instead.
