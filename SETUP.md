# Setting up Earshot

Earshot is a Mac app that writes down your calls as they happen (your side and the other side, separately) and gives you a summary when the call ends. Everything runs on your Mac: no account, no API key, and no audio or text is sent anywhere.

Setup takes about 15 minutes, most of it waiting for two one-time downloads.

## What you need

- **A Mac with Apple Silicon** (M1 or newer). Intel Macs are not supported. To check: Apple menu › About This Mac. "Chip: Apple M…" is Apple Silicon; "Processor: Intel" is not.
- **macOS 14.4 (Sonoma) or newer.** The same About This Mac window shows your version.
- **About 6 GB of free disk space**: 0.9 GB for the speech models and 4 GB for the summary model. The app itself is small.
- **An internet connection** for the downloads during setup. After that Earshot works offline.
- **No accounts, API keys or subscriptions.** Sending summaries to Slack is optional and is the only feature that needs anything from another service (see "Optional: Slack" below).

Earshot has so far been tested on one Mac (an M5 Pro with 48 GB of memory, macOS 27.2). The summary model needs about 4 GB of memory while it writes a summary, so summaries may be slow on a Mac with 8 GB.

## Step 1: Install Ollama (for summaries)

Ollama is a free app that runs the summary model on your Mac. Earshot transcribes without it, but cannot write summaries.

1. Download it from https://ollama.com/download and open the downloaded file.
2. Drag Ollama into Applications and open it once. A llama icon appears in the menu bar at the top of the screen.
3. If Ollama offers to sign in or create an account, skip it. Earshot does not need one.

You do not need to pick or download a model in Ollama. Earshot does that in step 5.

## Step 2: Install Earshot

1. Download Earshot: https://github.com/bradwasf/earshot/releases/latest/download/Earshot.dmg
2. Open the downloaded `Earshot.dmg`.
3. Drag **Earshot** onto the **Applications** folder in the window that opens.
4. Eject the "Earshot" disk (right-click it on the desktop or in Finder › Eject).

Always run Earshot from Applications, not from the disk image or the Downloads folder.

## Step 3: Open Earshot the first time

Earshot is not yet registered with Apple (not "notarized"), so macOS blocks it the first time and you have to approve it once. This is expected.

**macOS 15 (Sequoia) or newer:**

1. Open Earshot from Applications. A message appears: "“Earshot.app” Not Opened. Apple could not verify “Earshot.app” is free of malware…". Click **Done**. Do not click Move to Trash.
2. Open System Settings › **Privacy & Security** and scroll down to the Security section. It says Earshot was blocked. Click **Open Anyway**. (The button stays there for about an hour after step 1. If it is gone, open Earshot again and come back.)
3. Click **Open Anyway** again when asked, and confirm with your password or Touch ID.

**macOS 14 (Sonoma):**

1. In Applications, hold Control and click Earshot (or right-click it), then choose **Open**.
2. Click **Open** in the message that appears.

You only do this once. From then on Earshot opens normally.

*If you are comfortable with Terminal,* you can instead run this once, before opening Earshot for the first time:

```
xattr -dr com.apple.quarantine /Applications/Earshot.app
```

If it answers "Operation not permitted", use the System Settings steps above.

## Step 4: Wait for the speech models

The first time it opens, Earshot downloads its speech models (about 0.9 GB). The window says "Loading speech recognition model…" and the button in the top-right corner reads **Loading**. There is no progress bar; leave the window open. On a fast connection this takes about a minute, on a slow one several minutes.

When the button turns blue and reads **Record**, Earshot is ready.

If you see "Earshot could not start", check your internet connection and click **Try again**.

## Step 5: Make a short test recording

Do this once before your first real call. It gets the permission questions and the second download out of the way.

1. Click **Record**.
2. macOS asks two questions. Click **Allow** for both:
   - **Microphone**: so Earshot can hear you ("Me").
   - **System Audio Recording** ("Earshot would like to record this computer's audio"): so Earshot can hear the other people on the call ("Them").
3. Say a few sentences. They should appear in the window within a second.
4. Click the red timer button to stop.
5. Earshot now downloads the summary model (4 GB, once). The window shows "Pulling qwen3.5:4b-mlx" with a percentage. This can take anywhere from a few minutes to much longer on a slow connection. When it finishes, your summary appears.

Earshot does not need Screen Recording, Accessibility or any other permission.

If you clicked Don't Allow by mistake, turn Earshot on in System Settings › Privacy & Security › **Microphone**, and in Privacy & Security › **Screen & System Audio Recording** › *System Audio Recording Only*. Then quit and reopen Earshot.

## Using Earshot

- **Join your call as usual, then press Record** (or Command-R). You do not need to change any sound settings. Press the red timer button when the call is over.
- **Call prompts.** While Earshot is running, it notices when Zoom, Slack, Microsoft Teams, Discord, Webex or FaceTime starts a call and shows a small "Start transcribing?" card in the top-right corner of the screen. Calls in a browser tab (Google Meet) are not noticed; press Record for those.
- **Keep it running.** Closing the window leaves Earshot in the menu bar (waveform icon). To have it start with your Mac, turn on Settings › Calls › *Open Earshot when I log in*.
- **Your calls** are listed on the home screen and saved as plain files in the `Earshot/Calls` folder inside your home folder (`transcript.md` and `summary.md` for each call). Audio is not kept unless you turn on *Save raw audio* in Settings.
- **Export** on a finished call copies the summary or transcript, including a version formatted for pasting into Slack.

Tell the other people on a call that you are transcribing it. In many places that is legally required.

More detail on every feature: https://github.com/bradwasf/earshot#using-it

## Optional: Slack

**Copy for Slack** works with no setup: it puts the summary on your clipboard, ready to paste into Slack.

**Send to Slack** posts a summary straight to one channel. It needs a Slack "incoming webhook" address, which you or a Slack admin create once:

1. Go to https://api.slack.com/apps and create an app for your workspace.
2. Turn on *Incoming Webhooks* and add a webhook for the channel you want.
3. Copy the address it gives you (it starts with `https://hooks.slack.com/services/`) and paste it into Earshot › Settings › Slack. *Send a test message* checks that it works.

Treat that address like a password: anyone who has it can post to the channel. Earshot stores it in your Mac's keychain, and nothing is sent to Slack until you choose Send to Slack for a specific call.

## Updating

Download the new `Earshot.dmg` from the same link, quit Earshot, and drag the new version into Applications, choosing **Replace**. Your calls and settings are kept.

After an update, macOS treats Earshot as a new app: you approve it again as in step 3, and it asks for the microphone and system audio permissions again. If you set up Send to Slack, it may also ask for your Mac password to read the saved Slack address.

## If something goes wrong

- **"Them" stays empty.** The system audio permission is off. Turn Earshot on in System Settings › Privacy & Security › Screen & System Audio Recording › *System Audio Recording Only*, then record again.
- **"Me" stays empty.** Turn Earshot on in System Settings › Privacy & Security › Microphone, and check Earshot › Settings › Audio › My microphone.
- **"Summary failed" or "Ollama is not running".** Open the Ollama app (llama icon in the menu bar), then click **Regenerate Summary**. Your transcript is always saved either way.
- **The summary model download stopped.** Click **Regenerate Summary**; it picks up where it left off.
- **Earshot is slow to open after a macOS update.** It is preparing the speech models again. This takes up to a minute, once.
- **Still stuck?** Open an issue at https://github.com/bradwasf/earshot/issues and attach the file `earshot.log`. To find it, in Finder choose Go › Go to Folder and enter `~/Library/Logs/Earshot`. The log holds timings and error messages only, never what was said, but read it before you post it.

## Removing Earshot

1. Quit Earshot and drag it from Applications to the Trash.
2. To free the disk space used by the models: in Finder choose Go › Go to Folder, enter `~/Library/Application Support`, and delete the `FluidAudio` folder (speech models). Delete the Ollama app as well if you do not use it for anything else; its models are in the `.ollama` folder in your home folder.
3. Your transcripts and summaries stay in `Earshot/Calls` in your home folder until you delete them.

## Privacy

- Speech recognition and summaries run on your Mac. No audio, transcript or summary is uploaded.
- Earshot uses the internet for exactly three things: downloading the speech models (from huggingface.co) on first launch, downloading the summary model (through Ollama) on the first summary, and posting to Slack when you choose Send to Slack.
