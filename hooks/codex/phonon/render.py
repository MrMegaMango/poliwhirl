"""Render English locally for the existing pausable speech player."""

from pathlib import Path
import signal
import sys
import wave

signal.alarm(20)

def main():
    import ptts

    voice, output = sys.argv[1:]
    text = sys.stdin.read().strip()
    if not text:
        raise ValueError('empty speech text')
    model = ptts.TTS(str(Path(__file__).parent / 'model'), lang='en', quant='q8')
    # Only installed voices are accepted, so synthesis never needs a network call.
    if voice not in model.voices:
        raise ValueError('voice is not installed')
    model.save(output, text, voice=voice)
    with wave.open(output, 'rb') as audio:
        if audio.getnframes() == 0 or not any(audio.readframes(audio.getnframes())):
            raise ValueError('empty speech audio')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        # Never put the user's spoken text in logs or process arguments.
        print('phonon: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
