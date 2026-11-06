FROM python:3.12.13-slim-bookworm AS base

WORKDIR /src
COPY requirements.txt .
RUN pip install --no-cache-dir --timeout 120 --prefix=/install -r requirements.txt

FROM python:3.12.13-slim-bookworm AS runtime

WORKDIR /src
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN groupadd --gid 10001 usergroup \
    && useradd --uid 10001 --gid 10001 --no-create-home userapp \
    && chown userapp:usergroup /src
COPY --from=base /install /usr/local
COPY --chown=userapp:usergroup app ./app
USER userapp

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
