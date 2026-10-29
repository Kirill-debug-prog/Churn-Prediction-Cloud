# Churn Prediction Cloud

Учебный веб-сервис для оценки риска оттока клиентов телекоммуникационной компании. Пользователь вводит характеристики клиента, а модель возвращает класс и оценку риска. Прогноз экспериментальный: он не доказывает вероятность или причину ухода клиента.

## Состав проекта

- `backend/` — REST API на R (`plumber`) и общая логика проверки данных и прогнозирования.
- `frontend/` — веб-интерфейс на HTML, CSS и JavaScript.
- `scripts/` — подготовка данных, обучение и оценка моделей.
- `artifacts/` — обученная модель и JSON-файлы, необходимые API.
- `data/` — исходный CSV; в Git не включается.

## Запуск приложения в Docker

Требуется Docker Engine с Docker Compose. В корне проекта выполните:

```bash
docker compose up --build -d
```

Откройте <http://localhost:8080>. Проверка API: <http://localhost:8080/api/health>.

Остановить контейнеры:

```bash
docker compose down
```

Compose запускает API и frontend в отдельных контейнерах. Публикуется только frontend; nginx передаёт запросы `/api/` внутреннему API.

## Локальный запуск без Docker

Требуются R и пакеты проекта. Если модель ещё не обучена, сначала выполните обучение (см. следующий раздел). Затем запустите в двух терминалах из корня проекта:

```bash
Rscript backend/run.R
```

```bash
python -m http.server 8080 --directory frontend
```

Откройте <http://localhost:8080>. Не открывайте `index.html` напрямую через `file://`.

## Обучение модели

Установите пакеты и запустите полный конвейер:

```bash
Rscript scripts/00_install_packages.R
Rscript scripts/run_all.R
```

Если CSV отсутствует, скрипт попытается скачать его из UCI. После обучения в `artifacts/` создаются `model.rds`, `metadata.json`, `metrics.json` и `importance.json`. Для обновления модели в Docker пересоберите контейнеры:

```bash
docker compose up --build -d
```

## REST API

При запуске через Docker API доступен через frontend-адрес `/api/`. Основные маршруты:

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/health` | состояние сервиса и модели |
| GET | `/metadata` | описание модели и полей формы |
| GET | `/metrics` | сохранённые метрики |
| GET | `/importance` | важность признаков |
| POST | `/predict` | прогноз для клиента |

`POST /predict` принимает JSON вида `{"features": {"имя_признака": значение}}`. Имена и допустимые значения доступны в `/metadata`.

## Данные и лицензия

Используется набор [Iranian Churn](https://archive.ics.uci.edu/dataset/563/iranian+churn+dataset) из UCI Machine Learning Repository, DOI [10.24432/C5JW3Z](https://doi.org/10.24432/C5JW3Z). Это данные иранского телекоммуникационного оператора, не российского. Лицензия набора — [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); при распространении результатов указывайте источник. Код проекта распространяется по лицензии MIT (см. `LICENSE`).

## Тесты и подробные материалы

Тесты находятся в `tests/`. Документация по архитектуре и результаты проверок — в `docs/`. Каталоги `tests/` и `docs/` исключены из Git текущими правилами `.gitignore`.
