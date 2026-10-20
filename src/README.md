# src

Go ping-pong server + CLI. Stdlib only, no deps.

## Run

```sh
echo s3cret > /tmp/secret
SECRET_FILE_PATH=/tmp/secret go run .                       # server on :8080, sleeps 10s before listening
SECRET_FILE_PATH=/tmp/secret go run . --mode=cli --password=s3cret ping
```

Build: `go build -o ping-pong-app .`

## Env

- `SECRET_FILE_PATH`: required. File with token/password. Empty file = fatal.
- `PORT`: default `8080`.

## Endpoints

- `GET /ping`, `GET /pong`: need `Authorization: <secret>` or `Bearer <secret>`.
- `GET /health`: public. Probe target.
- `GET /`: HTML API page.
