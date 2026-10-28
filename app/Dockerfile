FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
RUN useradd -u 10001 app && chown -R app /app
USER app
EXPOSE 8080
CMD ["python", "main.py"]
