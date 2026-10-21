"""Minimal OpenAI-compatible text-to-speech for Paradee: POST /v1/audio/speech -> WAV."""
import io, os

import soundfile as sf
from fastapi import FastAPI
from fastapi.responses import Response
from paradee import Paradee, SAMPLE_RATE
from pydantic import BaseModel

tts = Paradee(threads=int(os.environ.get("TTS_THREADS", "1")))
app = FastAPI()


class Speech(BaseModel):
    input: str
    model: str = "paradee"
    voice: str | None = None
    speed: float = 1.0
    response_format: str = "wav"


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/v1/models")
def models():
    return {"data": [{"id": "paradee", "object": "model"}]}


@app.post("/v1/audio/speech")
def speech(req: Speech):
    buf = io.BytesIO()
    sf.write(buf, tts(req.input), SAMPLE_RATE, format="WAV", subtype="PCM_16")
    return Response(buf.getvalue(), media_type="audio/wav")
