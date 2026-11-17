#!/usr/bin/env python3
"""Builds a scripted three-person test call with macOS text-to-speech.

Output (16 kHz mono WAV, default ./test-artifacts):
  them.wav          system-audio channel: two remote speakers (Samantha, Daniel)
  me.wav            microphone channel: the local speaker (clean, as with headphones)
  me_with_echo.wav  microphone channel on speakers: local speaker + room echo of them.wav
  reference.json    ground-truth lines with speaker and start time

Standard library only. Usage: scripts/make-test-call.py [output-dir]
"""
import array, json, os, random, subprocess, sys, tempfile, wave

RATE = 16000
VOICES = {"Them 1": "Samantha", "Them 2": "Daniel", "Me": "Reed (English (US))"}

# (speaker, text, gap before this line in seconds; negative = overlaps the previous line)
SCRIPT = [
    ("Them 1", "Okay, I think everyone is here, so let's get started. The main topic today is the launch date for the mobile app.", 1.0),
    ("Me", "Thanks Sarah. Before we pick a date, I should mention that QA found two blocking bugs in the checkout flow yesterday.", 0.6),
    ("Them 2", "How serious are they? Can customers still complete a purchase?", 0.5),
    ("Me", "Not reliably. On older Android phones the payment sheet freezes about one time in five, and promo codes are applied twice.", 0.5),
    ("Them 1", "That rules out December third. David, what does marketing need if we slip?", 0.5),
    ("Them 2", "If we move to December tenth, we can still line up the press release and the email campaign. Anything later than that collides with the holiday freeze.", 0.3),
    ("Them 1", "Then let's decide it now. We are moving the launch to December tenth.", 0.4),
    ("Me", "Agreed. I will have both checkout bugs fixed by Wednesday, and I will send a test build to QA the same day.", 0.5),
    ("Them 2", "Great. I will update the press release and tell the agency about the new date by Friday.", 0.4),
    ("Them 1", "And I will update the roadmap and let the leadership team know this afternoon. What about the budget?", 0.5),
    ("Them 2", "We have spent forty two thousand dollars of the sixty thousand dollar launch budget, so there is room for one more week of paid ads.", 0.4),
    ("Me", "One open question from my side. Do we need a second round of load testing before the tenth?", 0.6),
    ("Them 1", "I am not sure yet. Let's look at the results of the bug fixes on Thursday and decide then.", 0.5),
    ("Them 2", "There is one more thing we have not resolved. Who owns customer support during launch week?", 0.5),
    ("Them 1", "Good point. I do not have an answer today, so let's put it on the agenda for Thursday.", 0.4),
    ("Me", "Sounds good. I will send the notes after this call.", 0.5),
    ("Them 1", "Perfect. Thanks everyone, talk to you on Thursday.", 0.4),
]


def speak(voice, text, path):
    subprocess.run(["say", "-v", voice, "-o", path, "--data-format=LEI16@16000", text], check=True)
    with wave.open(path, "rb") as handle:
        assert handle.getframerate() == RATE and handle.getnchannels() == 1
        return array.array("h", handle.readframes(handle.getnframes()))


def write(path, samples):
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(samples.tobytes())


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "test-artifacts"
    os.makedirs(out, exist_ok=True)
    clips, cursor, reference = [], 0, []
    with tempfile.TemporaryDirectory() as tmp:
        for index, (speaker, text, gap) in enumerate(SCRIPT):
            samples = speak(VOICES[speaker], text, os.path.join(tmp, f"{index}.wav"))
            start = max(0, cursor + int(gap * RATE))
            clips.append((speaker, start, samples))
            reference.append({"speaker": speaker, "start": round(start / RATE, 2),
                              "end": round((start + len(samples)) / RATE, 2), "text": text})
            cursor = start + len(samples)
    total = cursor + RATE
    tracks = {"them": array.array("h", bytes(2 * total)), "me": array.array("h", bytes(2 * total))}
    for speaker, start, samples in clips:
        track = tracks["me" if speaker == "Me" else "them"]
        for i, value in enumerate(samples):
            track[start + i] = max(-32768, min(32767, track[start + i] + value))

    # Microphone on speakers: direct path plus a few reflections of the far end, plus a noise floor.
    random.seed(7)
    echo = array.array("h", tracks["me"])
    taps = [(0.060, 0.30), (0.095, 0.14), (0.150, 0.08), (0.230, 0.04)]
    them = tracks["them"]
    for i in range(total):
        value = echo[i] + random.gauss(0, 30)
        for delay, gain in taps:
            j = i - int(delay * RATE)
            if j >= 0:
                value += them[j] * gain
        echo[i] = int(max(-32768, min(32767, value)))

    write(os.path.join(out, "them.wav"), tracks["them"])
    write(os.path.join(out, "me.wav"), tracks["me"])
    write(os.path.join(out, "me_with_echo.wav"), echo)
    with open(os.path.join(out, "reference.json"), "w") as handle:
        json.dump(reference, handle, indent=2)
    print(f"{out}: {total / RATE:.1f} s, {len(SCRIPT)} lines")


if __name__ == "__main__":
    main()
