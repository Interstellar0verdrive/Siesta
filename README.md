# Siesta

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Resources/icon/Siesta-light-1024.png">
  <source media="(prefers-color-scheme: light)" srcset="Resources/icon/Siesta-dark-1024.png">
  <img src="Resources/icon/Siesta-light-1024.png" width="128" align="right" alt="Siesta icon: a cat sleeping in front of the sun">
</picture>

A tiny macOS menu bar utility that gives a long-running video encoder periodic rests, so a laptop does not run flat out for hours on a long job or a queue of files.

Siesta counts the minutes the encoder has **actually** been working, then pauses it for a rest period and resumes it afterwards. The encoder simply continues from where it was: Siesta never restarts the job or touches the output file.

Currently it watches **HandBrake**. The code is structured so other encoders (Tdarr, Topaz Video AI, plain ffmpeg…) can be added as profiles.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Resources/siesta-hero-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="Resources/siesta-hero-light.png">
  <img src="Resources/siesta-hero-dark.png" alt="Illustration of Siesta in the macOS menu bar: HandBrake is working, with 12 minutes until the next pause and 18 of 30 work minutes elapsed">
</picture>

## How it works

- Every second Siesta looks at the processes that belong to HandBrake and adds up their CPU usage. HandBrake does the real encoding in a separate XPC worker: that is what Siesta pauses, so the HandBrake window stays responsive. If no worker can be identified, Siesta falls back to pausing the HandBrake processes it found.
- **Work minutes** only advance while HandBrake is encoding (CPU above a threshold, 50 % by default). If the queue is finished or HandBrake is closed, Siesta waits and says so.
- When the work minutes are up, the worker receives `SIGSTOP` for the configured **rest minutes**, then `SIGCONT`. CPU usage drops to zero during the rest.
- If HandBrake stays idle for at least the rest duration, the work counter resets: it already had its rest.
- Stopping or quitting Siesta always resumes a frozen worker first.

### At a glance

Siesta keeps its status visible without crowding the menu bar. The cat changes to show whether the cycle is stopped, HandBrake is encoding, taking a scheduled rest, or Siesta is waiting for work. During work and rest, the number beside it shows the minutes until the next change.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Resources/siesta-states-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="Resources/siesta-states-light.png">
  <img src="Resources/siesta-states-dark.png" alt="The four Siesta states: cycle stopped, working, resting, waiting">
</picture>

Clicking it opens a popover with the current state and countdown, a thin progress line for the running interval, the Work and Rest minutes, the Start/Stop cycle button, a collapsible activity log and a Quit button. The "Detached window" checkbox moves the same panel into a regular window; unchecking it brings the popover back. Changing the minutes while Siesta is running takes effect immediately and is noted in the log. "Stop cycle" stops Siesta's cycle only, never the encoder.

## Download

Grab `Siesta-<version>.zip` from the [Releases](https://github.com/Interstellar0verdrive/Siesta/releases) page, unzip it and move `Siesta.app` to your Applications folder. The app is universal (Apple Silicon and Intel) and needs macOS 13 or later.

Siesta is signed ad hoc and is not notarized, so macOS blocks the first launch with a "Siesta was not opened" dialog. Click **Done**, then go to System Settings → Privacy & Security, find the message about Siesta and click **Open Anyway**. This is only needed once. If you prefer the Terminal, removing the quarantine flag has the same effect:

```bash
xattr -d com.apple.quarantine /Applications/Siesta.app
```

## Updates

The current version is shown in small print next to the Quit button. While Siesta is running it asks GitHub for the latest release at launch and then every six hours; nothing runs while the app is closed.

When a newer release exists the version turns into an **Update to x.y.z** link. Clicking it downloads the release archive, verifies its SHA-256 checksum against the one published with the release, replaces the app in place (the old copy goes to the Trash) and relaunches. Because the new bundle is written by Siesta itself it carries no quarantine flag, so macOS does not ask for approval again: only the very first installation needs it. If the app lives in a folder Siesta cannot write to, or anything goes wrong, the link simply opens the release page instead.

## Building

Only the Xcode Command Line Tools are needed:

```bash
./build.sh
```

The app is produced at `build/Siesta.app` as a universal binary; `./build.sh --zip` also packages it for a release.

Launching the binary with `--start` starts the cycle immediately with the last saved values.

## Preferences

Stored in the `io.github.interstellar0verdrive.siesta` defaults domain: `work`, `rest` (minutes), `window` (detached window), `threshold` (CPU percentage considered "encoding", default 50, not exposed in the UI).

## Is pausing safe for the files?

A pause is `SIGSTOP`, which only suspends scheduling of the worker; `SIGCONT` lets it continue exactly where it was, and pending disk writes complete on resume. Siesta never reads, deletes or rewrites the output file. It cannot protect against unrelated failures such as a crash, a power loss or HandBrake being force-quit during an encode, exactly as without Siesta.

Siesta resumes a frozen worker when you stop the cycle, quit, or when it receives a termination signal (kill, logout). A `kill -9` cannot be intercepted and may leave the worker frozen; the file is still fine, and the next launch of Siesta detects and resumes it. You can also resume HandBrake's worker by hand:

```bash
kill -CONT $(pgrep -x HandBrakeXPCService)
```

## License

MIT, see [LICENSE](LICENSE).
