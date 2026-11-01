# Folassist (клиент + сервер), Alpine / arm64 / musl

Структура: Folclient/ Folserver/ common/ (общий protocol.zig лежит рядом).
Не в архиве (оставь свои): vendor/, voice/ (Piper), model.tar.gz (Vosk, 45572530 Б).

## Схема
- Клиент: Vosk на устройстве слушает постоянно, сам режет фразы и распознаёт.
  Фраза «дот <команда>» -> на сервер уходит ТОЛЬКО текст команды.
  Одиночное «дот» -> ждёт команду следующей фразой (6 с).
- Сервер: речь НЕ распознаёт. Текст -> погода / Groq -> Piper -> PCM клиенту.
- Ответ ИИ режется на куски только по знакам препинания (. ! ? , ; :), каждый озвучивается и сразу уходит клиенту.
- Клиент открывает ALSA-вывод один раз на весь ответ и закрывает после последнего куска.

## Протокол (TCP :9000), кадр (7 байт): magic(0xFA) ver(7) [type:3 бита | flags:5 бит] len(u32 LE), затем payload
cmd (type 2), flags = код: 00 модель, 01 погода, 10 ИИ, 11 музыка; payload: текст
type 1 hello  type 2 text (команда)  type 3 reply (u32 rate + PCM, пусто = «нет ответа»)
type 5 play (путь HTTP-потока, приходит перед reply)

## Модель по код 00
Если папки --model нет, клиент шлёт код 00, кладёт архив в /dev/shm/model.tar.gz,
`tar -xzf /dev/shm/model.tar.gz -C /dev/shm/`, удаляет архив.
--model должен совпадать с именем папки ВНУТРИ архива (по умолчанию
/dev/shm/vosk-model-small-ru-0.22). После перезагрузки /dev/shm пуст -> скачает снова.

## Ютуб
Голос: «дот включи ютуб <запрос>» (или «дот включи <запрос>») -> сервер шлёт клиенту
путь /yt?q=..., клиент запускает `wget -qO- http://сервер:9001/yt?q=... | aplay -q`.
Сервер на HTTP :9001: `yt-dlp ... | ffmpeg -f wav` прямо в сокет (mpv не нужен: он плеер).
Ссылкой: http://сервер:9001/yt?url=https://youtu.be/...
«дот стоп» / «дот хватит» — клиент убивает поток и выключает звонящий будильник (рингтон крутится по кругу до стопа).
На сервере нужны: yt-dlp, ffmpeg. На клиенте: wget, aplay (alsa-utils), tar.

## Запуск
cd Folserver && zig build -Doptimize=ReleaseFast
export GROQ_API_KEY=gsk_...
./zig-out/bin/folserver --model-archive=model.tar.gz --voice=voice/ru_RU-ruslan-medium.onnx \
  --espeak=/usr/share/espeak-ng-data --port=9000 --http-port=9001 [--proxy=http://host:port]

cd Folclient && zig build -Doptimize=ReleaseSmall
./zig-out/bin/folclient --id=1 --server=192.168.1.100:9000 --http-port=9001 \
  --model=/dev/shm/vosk-model-small-ru-0.22 --wake-sound=wake_sound.wav \
  --city=Омске --lat=54.99 --lon=73.37

## Опции
- `./folclient --help` — все опции клиента.
- `--gate=N` — не гонять Vosk на тишине (экономит CPU). Подбери N по `--level`, обычно 100–300.
- Сервер: если `voice/*.onnx.json` пустой или отсутствует — сервер сразу пишет понятную ошибку.
