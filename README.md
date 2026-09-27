# Hushcast: noise to CarPlay, podcast to AirPods (test build)

The app generates white, pink or brown noise itself and streams podcasts from their public RSS feeds.
It uses `AVAudioSession` category `.multiRoute` to send each stream to a different output.
Whether iOS allows **CarPlay + AirPods** as simultaneous outputs is undocumented; this build exists to find out.

## 1. Build the app on GitHub (no Mac needed)

1. On github.com, create a new repository called `Hushcast`.
   - **Public**: macOS build minutes are free.
   - **Private**: the free quota (about 200 macOS minutes a month) is enough for about 40 builds.
2. Choose **Add file → Upload files** and upload `Hushcast.swift` and `project.yml`. Commit.
3. Choose **Add file → Create new file**.
   - Type the name exactly: `.github/workflows/build.yml`
   - Paste the contents of `build.yml` and commit. This starts the build.
4. Open the **Actions** tab and the running job; it takes about 5 minutes.
   - On success, download the **Hushcast-ipa** artifact and unzip it to get `Hushcast.ipa`.
   - On failure, download **build-log** and send me the lines containing `error:`.

## 2. Install on the iPhone from Windows (free Apple ID)

1. Install **iTunes** and **iCloud** from apple.com. Use the web installers, not the Microsoft Store versions.
2. Install **Sideloadly** (sideloadly.io).
3. Connect the iPhone by USB and tap "Trust this computer."
4. In Sideloadly, drag in `Hushcast.ipa`, enter an Apple ID, and click **Start**.
   A secondary Apple ID works if you'd rather not use your main one.
5. On the iPhone:
   - Settings → Privacy & Security → **Developer Mode** → On. The phone restarts.
   - Settings → General → VPN & Device Management → trust your Apple ID.
6. Free signing expires after **7 days**. After that, re-run Sideloadly; the app's data is kept.

## 3. Test protocol

1. **At home, AirPods only.** Search for a show, tap an episode (it downloads first), and check that playback and the controls work.
   Start the noise too: with a single output, both sounds play in the AirPods, which is expected.
2. **In the car.** Connect CarPlay, then the AirPods, then open the app.
   - The **Outputs** section decides the question. If it lists two outputs (CarPlay + AirPods), the split is possible.
     If it lists one, iOS will not split with this pair and no app can.
3. If two outputs are listed:
   - Start the noise at low volume, then the podcast, with Method **A**.
   - If the sound is not split, choose Method **B** and tap **Apply routing**.
4. Try wired and wireless CarPlay separately if you can; they behave differently.
5. Tap **Copy log** and send the log to me.

## Safety behaviour built in

- The podcast is never played on CarPlay. If the AirPods are not an output, the podcast refuses to start.
- If the AirPods disconnect, the podcast pauses. If CarPlay disconnects, the noise stops.
- Car and AirPods play/pause buttons control the podcast, not the noise.

## Known limitations

- Episodes are downloaded before playing; they are not streamed.
- With Method A, a **mono** episode may play in one earbud only. Method B does not have this problem.
- Whether the code compiles is untested: the first build may need a fix.
