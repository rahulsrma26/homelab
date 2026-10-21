# Paradee (8M-parameter English TTS, CPU) behind a minimal OpenAI-style /v1/audio/speech
FROM python:3.11-slim
ARG PARADEE_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir "git+https://github.com/sahilmahendrakar/paradee@${PARADEE_REF}" soundfile fastapi uvicorn \
 && python -m spacy download en_core_web_sm \
 && python -c "from paradee import Paradee; Paradee()"
COPY server.py /server.py
EXPOSE 8080
HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"
CMD ["uvicorn", "--app-dir", "/", "server:app", "--host", "0.0.0.0", "--port", "8080"]
