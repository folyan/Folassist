# Голосовой ассистент Folassist (Zig + Vosk + Piper + Groq AI)

Голосовой ассистент, написанный на языке Zig.

## Как это работает?
1. Распознавание речи: Локально через Vosk, ожидает кодовое слово активации
2. Синтез речи: Локально через Piper TTS с постоянным кэшированием готовых аудиофрагментов на диск, часто используемые фразы и ответы синтезируются один раз, после чего воспроизводятся мгновенно
3. Музыка и стриминг: По запросу «включи <название>» находит трек на YouTube через yt-dlp и стриминг через mpv, ваще, yt-dlp будто оверкилл, но альтернатив нормальных нет
4. ИИ: Если после кодового слова не команда текст улетает в Groq API (openai/gpt-oss-20b) и ответ озвучивается
5. Таймеры: Поддерживает будильники и напоминания

---

Перед сборкой убедитесь, что у вас установлены следующие пакеты:
- Zig версии 0.17.0
- build-base, alsa-lib-dev, libpiper-dev, vosk-dev, onnxruntime
- поменять в src/main.zig:
 const current_city = weather.Config{
    .city_in = "Омске",
    .latitude = 54.99,
    .longitude = 73.37,
};
---

## Что нужно сделать для запуска
P.S зависимости под Alpine Linux, под другие дистрибутивы сами подбирайте

1. Скачать vosk ( https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip ), распаковать, указать папку в --model=папка/
2. Скачать piper ( https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/ru/ru_RU/ ), распаковать .onnx, .onnx.json желаемого голоса, указать в --voice=файл.onnx, где рядом .onnx.json
3. Получить API-ключ Groq и потом export GROQ_API_KEY="ТВОЙ КЛЮЧ"
4. Установить зависимости: apk add libvosk libpiper onnxruntime mpv yt-dlp-core
5. Запустить бинарник Folassist с нужными флагами, пример: ./Folassist --model=vosk/ --voice=voice/ru_RU-ruslan-medium.onnx --wake="дот" --ringtone=ringtone.wav, где --wake=Ключевое слово, а --ringtone=рингтон для будильника
