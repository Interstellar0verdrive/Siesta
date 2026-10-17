# Siesta

<img src="Resources/icon/Siesta-light-1024.png" width="128" align="right" alt="Siesta icon: a cat sleeping in front of the sun">

A tiny macOS menu bar utility that gives a long-running video encoder periodic rests, so a laptop does not run flat out for hours while converting a whole season.

Siesta counts the minutes the encoder has **actually** been working, then freezes it for a rest period and resumes it afterwards. Nothing is lost: the frozen process simply continues from where it was, the output file is untouched.

Currently it watches **HandBrake**. The code is structured so other encoders (Tdarr, Topaz Video AI, plain ffmpeg…) can be added as profiles.

## How it works

- Every second Siesta looks at the processes that belong to HandBrake and adds up their CPU usage. HandBrake does the real encoding in a separate XPC worker process, so that is what gets measured and paused; the HandBrake window stays responsive.
- **Work minutes** only advance while HandBrake is encoding (CPU above a threshold, 50 % by default). If the queue is finished or HandBrake is closed, Siesta waits and says so.
- When the work minutes are up, the worker processes receive `SIGSTOP` for the configured **rest minutes**, then `SIGCONT`. CPU usage drops to zero during the rest.
- If HandBrake stays idle for at least the rest duration, the work counter resets: it already had its rest.
- Stopping or quitting Siesta always resumes a frozen worker first.

The menu bar item shows the current state with system symbols: a cat when stopped, an hourglass while waiting for work, play with the minutes left until the next rest, pause with the minutes left until resume. Clicking it opens a popover; a checkbox switches to a detached window instead. Changing the minutes while Siesta is running takes effect immediately and is noted in the log.

## Building

Only the Xcode Command Line Tools are needed:

```bash
./build.sh
```

The app is produced at `build/Siesta.app`. It is ad-hoc signed, so the first launch may require right-click → Open.

Launching the binary with `--start` starts the cycle immediately with the last saved values.

## Preferences

Stored in the `io.github.interstellar0verdrive.siesta` defaults domain: `work`, `rest` (minutes), `window` (detached window), `threshold` (CPU percentage considered "encoding", default 50, not exposed in the UI).

## Is pausing safe for the files?

Yes. `SIGSTOP` only suspends scheduling of the process; no operation is interrupted or cancelled. Pending disk writes complete identically on resume. It is the same mechanism macOS uses to suspend background apps. The only practical caveat: if Siesta is killed with `kill -9` while a worker is frozen, the worker stays frozen (the file is still fine). Unfreeze it with:

```bash
kill -CONT $(pgrep -x HandBrakeXPCService)
```

## License

MIT, see [LICENSE](LICENSE).
