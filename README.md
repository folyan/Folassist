# Folassist

Голосовой ассистент. Клиент слушает микрофон, сервер отвечает голосом.

Слово активации: **фокус**.

## Что скачать

Actions → **client** или **server** → Run workflow → скачай артефакт.

- клиент: `folclient-aarch64` или `folclient-armhf`
- сервер: папка `folserver-<arch>-<glibc|musl>`, Alpine — `musl`, Debian/Ubuntu — `glibc`

## Запуск сервера

Нужен ключ Groq и файл голоса Piper (`.onnx` и рядом `.onnx.json`).

```
export GROQ_API_KEY=gsk_...
./run.sh --voice=voice/ru_RU-name-medium.onnx
```

## Запуск клиента

```
./folclient --server=IP_СЕРВЕРА:9000
```

Подробнее: `./folclient --help` и `./run.sh --help`.

## Автообновление

Сервер сам скачивает клиентов из последнего релиза и раздаёт их по HTTP вместе с `sha256sums.txt`. Если версия сервера новее, клиент проверяет хеш, заменяет себя и перезапускается. Старые клиенты (до этой версии) обновить нужно один раз вручную.
