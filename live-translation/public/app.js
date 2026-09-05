/* Live Translation: English speech in -> Marathi speech out.
 *
 * Pipeline (all on the phone, in the browser):
 *   microphone -> Azure Speech translation (websocket) -> Marathi text + Marathi audio
 *   -> Web Audio queue -> earphones
 *
 * Two engines:
 *   builtin : the translation stream also returns synthesized Marathi audio
 *             (lowest latency, one connection).
 *   tts     : translation returns text only; a separate SpeechSynthesizer
 *             speaks it (lets us control speaking rate).
 */
(() => {
  "use strict";
  const SDK = window.SpeechSDK;

  // ---------- DOM ----------
  const $ = (id) => document.getElementById(id);
  const bigbtn = $("bigbtn");
  const statusEl = $("status");
  const statusText = $("statusText");
  const textEl = $("text");
  const settingsEl = $("settings");

  // ---------- settings (persisted on the phone) ----------
  const DEFAULTS = {
    voice: "mr-IN-AarohiNeural",
    engine: "builtin",
    rate: "1.0",
    fontsize: "1.7rem",
    pin: "",
  };
  const settings = loadSettings();
  applyFontSize();

  function loadSettings() {
    try {
      return { ...DEFAULTS, ...JSON.parse(localStorage.getItem("lt-settings") || "{}") };
    } catch {
      return { ...DEFAULTS };
    }
  }
  function saveSettings() {
    try { localStorage.setItem("lt-settings", JSON.stringify(settings)); } catch {}
  }
  function applyFontSize() { textEl.style.fontSize = settings.fontsize; }

  $("gear").onclick = () => {
    $("voice").value = settings.voice;
    $("engine").value = settings.engine;
    $("rate").value = settings.rate;
    $("fontsize").value = settings.fontsize;
    $("pin").value = settings.pin;
    settingsEl.classList.add("open");
  };
  $("closeSettings").onclick = () => settingsEl.classList.remove("open");
  $("saveSettings").onclick = () => {
    settings.voice = $("voice").value;
    settings.engine = $("engine").value;
    settings.rate = $("rate").value;
    settings.fontsize = $("fontsize").value;
    settings.pin = $("pin").value.trim();
    saveSettings();
    applyFontSize();
    settingsEl.classList.remove("open");
  };

  // ---------- status / transcript UI ----------
  const MAX_LINES = 30;
  let partialEl = null;

  function setStatus(kind, mr, en) {
    statusEl.className = kind; // "", "live", "error"
    statusText.textContent = en ? `${mr} · ${en}` : mr;
  }
  function showPartial(text) {
    if (!text) return;
    if (!partialEl) {
      partialEl = document.createElement("p");
      partialEl.className = "partial";
      textEl.appendChild(partialEl);
    }
    partialEl.textContent = text;
    textEl.scrollTop = textEl.scrollHeight;
  }
  function showFinal(text) {
    if (partialEl) { partialEl.remove(); partialEl = null; }
    if (!text) return;
    const p = document.createElement("p");
    p.textContent = text;
    textEl.appendChild(p);
    while (textEl.children.length > MAX_LINES) textEl.removeChild(textEl.firstChild);
    textEl.scrollTop = textEl.scrollHeight;
  }
  function clearText() { textEl.innerHTML = ""; partialEl = null; }

  // ---------- audio playback queue ----------
  // One AudioContext, created/resumed inside the Start tap so iOS allows playback.
  let audioCtx = null;
  let nextStartTime = 0;
  let activeSources = new Set();

  function ensureAudio() {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === "suspended") audioCtx.resume();
    // iOS quirk: play a silent buffer inside the gesture to fully unlock output.
    const b = audioCtx.createBuffer(1, 1, audioCtx.sampleRate);
    const s = audioCtx.createBufferSource();
    s.buffer = b; s.connect(audioCtx.destination); s.start(0);
  }

  function enqueueBuffer(buffer) {
    if (!audioCtx || !buffer) return;
    const src = audioCtx.createBufferSource();
    src.buffer = buffer;
    src.connect(audioCtx.destination);
    const now = audioCtx.currentTime;
    const startAt = Math.max(now + 0.02, nextStartTime);
    src.start(startAt);
    nextStartTime = startAt + buffer.duration;
    activeSources.add(src);
    src.onended = () => activeSources.delete(src);
  }

  function stopPlayback() {
    for (const s of activeSources) { try { s.stop(); } catch {} }
    activeSources.clear();
    nextStartTime = 0;
  }

  // Decode WAV (RIFF, PCM16 or float32) without relying on decodeAudioData,
  // because streamed WAV headers often carry a bogus data length.
  function decodeWav(ab) {
    const dv = new DataView(ab);
    const tag = (o) => String.fromCharCode(dv.getUint8(o), dv.getUint8(o + 1), dv.getUint8(o + 2), dv.getUint8(o + 3));
    if (ab.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;
    let off = 12, fmt = null, dataOff = -1, dataLen = 0;
    while (off + 8 <= ab.byteLength) {
      const id = tag(off);
      let len = dv.getUint32(off + 4, true);
      const body = off + 8;
      if (id === "fmt ") {
        fmt = {
          format: dv.getUint16(body, true),
          channels: dv.getUint16(body + 2, true),
          sampleRate: dv.getUint32(body + 4, true),
          bits: dv.getUint16(body + 14, true),
        };
      } else if (id === "data") {
        dataOff = body;
        // Streaming encoders write 0 or 0xFFFFFFFF here; trust the buffer instead.
        dataLen = Math.min(len === 0 || len === 0xffffffff ? Infinity : len, ab.byteLength - body);
        break;
      }
      off = body + len + (len & 1);
    }
    if (!fmt || dataOff < 0 || fmt.channels < 1) return null;
    const bytesPer = fmt.bits / 8;
    const frames = Math.floor(dataLen / (bytesPer * fmt.channels));
    if (frames <= 0) return null;
    const buf = audioCtx.createBuffer(fmt.channels, frames, fmt.sampleRate);
    for (let ch = 0; ch < fmt.channels; ch++) {
      const out = buf.getChannelData(ch);
      for (let i = 0; i < frames; i++) {
        const p = dataOff + (i * fmt.channels + ch) * bytesPer;
        if (fmt.format === 3 && fmt.bits === 32) out[i] = dv.getFloat32(p, true);
        else if (fmt.bits === 16) out[i] = dv.getInt16(p, true) / 32768;
        else if (fmt.bits === 8) out[i] = (dv.getUint8(p) - 128) / 128;
        else return null;
      }
    }
    return buf;
  }

  async function playArrayBuffer(ab) {
    if (!ab || ab.byteLength === 0 || !audioCtx) return;
    let buffer = decodeWav(ab);
    if (!buffer) {
      try { buffer = await audioCtx.decodeAudioData(ab.slice(0)); }
      catch (e) { console.warn("Could not decode audio", e); return; }
    }
    enqueueBuffer(buffer);
  }

  // ---------- Azure token ----------
  let tokenInfo = null; // { token, region, refreshInSec }
  async function fetchToken() {
    const res = await fetch("/api/token", {
      headers: settings.pin ? { "X-App-Pin": settings.pin } : {},
      cache: "no-store",
    });
    if (res.status === 401) throw new Error("PIN_REQUIRED");
    if (!res.ok) throw new Error(`Token error ${res.status}`);
    tokenInfo = await res.json();
    return tokenInfo;
  }

  // ---------- session ----------
  let state = "idle"; // idle | starting | listening | stopping
  let recognizer = null;
  let synthesizer = null;
  let synthChain = Promise.resolve();
  let refreshTimer = null;
  let wakeLock = null;
  let restartAttempts = 0;
  let synthChunks = []; // builtin engine: accumulate audio chunks per utterance

  bigbtn.onclick = () => {
    if (state === "idle") start();
    else if (state === "listening") stop();
  };

  async function start() {
    state = "starting";
    bigbtn.disabled = true;
    setStatus("", "जोडत आहे…", "Connecting");
    clearText();
    try {
      ensureAudio();              // must happen inside the tap
      await requestWakeLock();
      await fetchToken();
      await startRecognizer();
      state = "listening";
      restartAttempts = 0;
      bigbtn.disabled = false;
      bigbtn.className = "stop";
      bigbtn.innerHTML = "थांबवा<small>Stop</small>";
      setStatus("live", "ऐकत आहे…", "Listening");
      scheduleTokenRefresh();
    } catch (err) {
      console.error(err);
      await teardown();
      state = "idle";
      bigbtn.disabled = false;
      if (String(err.message) === "PIN_REQUIRED") {
        setStatus("error", "PIN चुकीचा", "Open ⚙ and enter the access PIN");
      } else if (/NotAllowed|Permission|denied/i.test(String(err))) {
        setStatus("error", "मायक्रोफोन परवानगी नाही", "Microphone permission denied");
      } else {
        setStatus("error", "त्रुटी", err.message || "Could not start");
      }
    }
  }

  async function stop() {
    state = "stopping";
    bigbtn.disabled = true;
    await teardown();
    state = "idle";
    bigbtn.disabled = false;
    bigbtn.className = "";
    bigbtn.innerHTML = "सुरू करा<small>Start</small>";
    setStatus("", "थांबले", "Stopped");
  }

  async function teardown() {
    clearTimeout(refreshTimer); refreshTimer = null;
    stopPlayback();
    const r = recognizer; recognizer = null;
    if (r) {
      await new Promise((res) => r.stopContinuousRecognitionAsync(res, res));
      try { r.close(); } catch {}
    }
    const s = synthesizer; synthesizer = null;
    if (s) { try { s.close(); } catch {} }
    synthChain = Promise.resolve();
    synthChunks = [];
    releaseWakeLock();
  }

  function buildTranslationConfig() {
    const cfg = SDK.SpeechTranslationConfig.fromAuthorizationToken(tokenInfo.token, tokenInfo.region);
    cfg.speechRecognitionLanguage = "en-US";
    cfg.addTargetLanguage("mr");
    if (settings.engine === "builtin") cfg.voiceName = settings.voice;
    // Shorter silence-based segmentation = phrases are finalized (and spoken) sooner.
    cfg.setProperty(SDK.PropertyId.Speech_SegmentationSilenceTimeoutMs, "700");
    // Keep the connection alive through long pauses (hymns, silence, procession).
    cfg.setProperty(SDK.PropertyId.SpeechServiceConnection_InitialSilenceTimeoutMs, "60000");
    return cfg;
  }

  function startRecognizer() {
    return new Promise((resolve, reject) => {
      const cfg = buildTranslationConfig();
      const audio = SDK.AudioConfig.fromDefaultMicrophoneInput();
      const rec = new SDK.TranslationRecognizer(cfg, audio);
      recognizer = rec;

      rec.recognizing = (_s, e) => {
        if (state !== "listening") return;
        showPartial(e.result.translations.get("mr"));
      };

      rec.recognized = (_s, e) => {
        if (state !== "listening" || e.result.reason !== SDK.ResultReason.TranslatedSpeech) return;
        const mr = e.result.translations.get("mr");
        if (!mr || !mr.trim()) return;
        showFinal(mr);
        if (settings.engine === "tts") speakWithTts(mr);
      };

      rec.synthesizing = (_s, e) => {
        // builtin engine: audio arrives in one or more chunks, then a
        // zero-length "completed" event.  Accumulate, then decode the whole utterance.
        const a = e.result.audio;
        if (a && a.byteLength > 0) {
          synthChunks.push(new Uint8Array(a));
        } else if (synthChunks.length) {
          const total = synthChunks.reduce((n, c) => n + c.byteLength, 0);
          const joined = new Uint8Array(total);
          let o = 0;
          for (const c of synthChunks) { joined.set(c, o); o += c.byteLength; }
          synthChunks = [];
          if (state === "listening") playArrayBuffer(joined.buffer);
        }
      };

      rec.canceled = (_s, e) => {
        if (e.reason === SDK.CancellationReason.Error) {
          console.error("Canceled:", e.errorCode, e.errorDetails);
          if (state === "listening") handleDrop(e.errorDetails);
        }
      };

      rec.sessionStopped = () => {
        if (state === "listening") handleDrop("session stopped");
      };

      if (settings.engine === "tts") {
        const scfg = SDK.SpeechConfig.fromAuthorizationToken(tokenInfo.token, tokenInfo.region);
        scfg.speechSynthesisVoiceName = settings.voice;
        scfg.speechSynthesisOutputFormat = SDK.SpeechSynthesisOutputFormat.Riff24Khz16BitMonoPcm;
        synthesizer = new SDK.SpeechSynthesizer(scfg, null); // null => give us bytes, don't auto-play
      }

      rec.startContinuousRecognitionAsync(resolve, reject);
    });
  }

  function speakWithTts(text) {
    const synth = synthesizer;
    if (!synth) return;
    const ssml =
      `<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="mr-IN">` +
      `<voice name="${settings.voice}"><prosody rate="${Number(settings.rate) || 1}">${escapeXml(text)}</prosody></voice></speak>`;
    // Chain so sentences are spoken in the order they were said.
    synthChain = synthChain.then(
      () => new Promise((resolve) => {
        synth.speakSsmlAsync(
          ssml,
          (result) => {
            if (state === "listening" && result.reason === SDK.ResultReason.SynthesizingAudioCompleted) {
              playArrayBuffer(result.audioData);
            } else if (result.errorDetails) {
              console.warn("TTS:", result.errorDetails);
            }
            resolve();
          },
          (err) => { console.warn("TTS error", err); resolve(); }
        );
      })
    );
  }

  function escapeXml(s) {
    return s.replace(/[<>&'"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" }[c]));
  }

  // Connection dropped mid-mass (wifi blip, token issue): quietly reconnect.
  async function handleDrop(detail) {
    if (state !== "listening") return;
    restartAttempts++;
    if (restartAttempts > 5) {
      await stop();
      setStatus("error", "जोडणी तुटली", "Connection lost. Tap Start again.");
      return;
    }
    setStatus("", "पुन्हा जोडत आहे…", "Reconnecting");
    const r = recognizer; recognizer = null;
    if (r) { try { r.close(); } catch {} }
    const s = synthesizer; synthesizer = null;
    if (s) { try { s.close(); } catch {} }
    synthChunks = [];
    await new Promise((res) => setTimeout(res, 1500 * restartAttempts));
    if (state !== "listening") return;
    try {
      await fetchToken();
      await startRecognizer();
      setStatus("live", "ऐकत आहे…", "Listening");
    } catch (err) {
      console.error("Reconnect failed", err, detail);
      handleDrop(String(err));
    }
  }

  // Azure tokens expire after 10 min; swap in a fresh one before that.
  function scheduleTokenRefresh() {
    clearTimeout(refreshTimer);
    const secs = Math.max(60, Math.min(540, (tokenInfo && tokenInfo.refreshInSec) || 480));
    refreshTimer = setTimeout(async () => {
      if (state !== "listening") return;
      try {
        await fetchToken();
        if (recognizer) recognizer.authorizationToken = tokenInfo.token;
        if (synthesizer) synthesizer.authorizationToken = tokenInfo.token;
      } catch (e) {
        console.warn("Token refresh failed", e);
      }
      scheduleTokenRefresh();
    }, secs * 1000);
  }

  // Keep the screen on so iOS/Android don't suspend the microphone.
  async function requestWakeLock() {
    try {
      if ("wakeLock" in navigator) wakeLock = await navigator.wakeLock.request("screen");
    } catch (e) { console.warn("Wake lock unavailable", e); }
  }
  function releaseWakeLock() {
    if (wakeLock) { wakeLock.release().catch(() => {}); wakeLock = null; }
  }
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && state === "listening") {
      requestWakeLock();
      if (audioCtx && audioCtx.state === "suspended") audioCtx.resume();
    }
  });

  if (!SDK) {
    setStatus("error", "त्रुटी", "Speech SDK failed to load");
    bigbtn.disabled = true;
  }
})();
