FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd -m -u 10001 retro && mkdir /app/data && chown retro:retro /app/data
COPY --chown=retro:retro . .
USER retro
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "services.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
