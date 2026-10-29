# backend/plumber.R
# ---------------------------------------------------------------------------
# REST API сервиса Churn Prediction Cloud (пакет plumber).
# Запуск:  Rscript backend/run.R   (из корня проекта)
#
# Эндпоинты: GET /health, GET /metadata, GET /metrics, GET /importance, POST /predict
# Принципы:
#   - модель и JSON-файлы загружаются ОДИН раз при запуске, обучения в API нет;
#   - введённые данные клиентов нигде не сохраняются и не логируются;
#   - любой некорректный запрос возвращает JSON с понятной ошибкой, а не роняет сервер.
# ---------------------------------------------------------------------------

# --- Пути ------------------------------------------------------------------
# Структура одинакова локально и в Docker: <корень>/backend и <корень>/artifacts.
backend_dir <- Sys.getenv("CHURN_BACKEND_DIR", unset = "")
if (!nzchar(backend_dir)) {
  backend_dir <- if (file.exists("helpers.R")) "." else "backend"
}
backend_dir <- normalizePath(backend_dir)
artifacts_dir <- Sys.getenv("ARTIFACTS_DIR", unset = file.path(dirname(backend_dir), "artifacts"))

source(file.path(backend_dir, "helpers.R"), encoding = "UTF-8")
suppressPackageStartupMessages({
  library(rpart)
  library(randomForest)
}) # нужны для predict()

# --- Загрузка артефактов (при старте) ----------------------------------------
BUNDLE <- load_bundle(file.path(artifacts_dir, "model.rds"))
SPEC <- BUNDLE$spec

read_json_file <- function(name, fallback = NULL) {
  path <- file.path(artifacts_dir, name)
  if (!file.exists(path)) {
    if (is.null(fallback)) stop("Не найден файл ", path, ". Выполните обучение: Rscript scripts/run_all.R", call. = FALSE)
    message("Предупреждение: нет файла ", path, " - будет возвращён пустой ответ.")
    return(fallback)
  }
  jsonlite::read_json(path, simplifyVector = FALSE)
}
METADATA <- read_json_file("metadata.json")
METRICS <- read_json_file("metrics.json")
IMPORTANCE <- read_json_file("importance.json",
  fallback = list(
    available = FALSE, items = list(),
    note = "Анализ важности признаков не выполнен."
  )
)

# --- CORS: разрешённые адреса frontend ---------------------------------------
DEFAULT_ORIGINS <- paste("http://localhost:8080", "http://127.0.0.1:8080",
  "http://localhost:5500", "http://127.0.0.1:5500",
  "http://localhost:3000",
  sep = ","
)
ALLOWED_ORIGINS <- sub("/+$", "", trimws(strsplit(Sys.getenv("ALLOWED_ORIGINS", unset = DEFAULT_ORIGINS), ",")[[1]]))
ALLOWED_ORIGINS <- ALLOWED_ORIGINS[nzchar(ALLOWED_ORIGINS)]
MAX_BODY_BYTES <- 20000L

message(sprintf(
  "Модель загружена: %s (порог %.2f). Разрешённые origin: %s",
  BUNDLE$model_label, BUNDLE$threshold, paste(ALLOWED_ORIGINS, collapse = ", ")
))

# --- Настройка роутера -------------------------------------------------------
#* @plumber
function(pr) {
  # Единый JSON-формат ответа (скаляры без обёртки в массив), в том числе для ошибок.
  pr <- plumber::pr_set_serializer(pr, plumber::serializer_unboxed_json(na = "null", digits = NA))
  plumber::pr_set_error(pr, function(req, res, err) {
    # Если ошибка случилась ДО входа в обработчик /predict - это не разобранное тело
    # запроса (например, битый JSON): отвечаем 400. Иначе - внутренняя ошибка 500.
    before_handler <- identical(req$REQUEST_METHOD, "POST") &&
      identical(req$PATH_INFO, "/predict") && !isTRUE(req$.handler_started)
    if (before_handler) {
      res$status <- 400L
      return(list(error = "Некорректный JSON в теле запроса.", details = list()))
    }
    message("Внутренняя ошибка: ", conditionMessage(err)) # тело запроса в лог НЕ пишем
    res$status <- 500L
    list(error = "Внутренняя ошибка сервера.", details = list())
  })
}

# --- Фильтр CORS -------------------------------------------------------------
#* @filter cors
function(req, res) {
  origin <- req$HTTP_ORIGIN
  if (!is.null(origin) && sub("/+$", "", origin) %in% ALLOWED_ORIGINS) {
    res$setHeader("Access-Control-Allow-Origin", origin)
    res$setHeader("Vary", "Origin")
    res$setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    res$setHeader("Access-Control-Allow-Headers", "Content-Type")
    res$setHeader("Access-Control-Max-Age", "86400")
  }
  if (identical(req$REQUEST_METHOD, "OPTIONS")) { # предзапрос браузера (preflight)
    res$status <- 200L
    return(list())
  }
  plumber::forward()
}

# --- Эндпоинты ---------------------------------------------------------------

#* Проверка работоспособности
#* @get /health
function() {
  list(
    status = "ok", model_loaded = TRUE, model = BUNDLE$model_label,
    time_utc = format(Sys.time(), tz = "UTC", usetz = FALSE, format = "%Y-%m-%dT%H:%M:%SZ")
  )
}

#* Описание модели, признаков, допустимых категорий и значений по умолчанию
#* @get /metadata
function() METADATA

#* Метрики качества обученных моделей
#* @get /metrics
function() METRICS

#* Глобальная важность признаков
#* @get /importance
function() IMPORTANCE

#* Прогноз оттока для одного клиента
#* Тело запроса: {"features": {"call_failure": 3, "complains": 0, ...}}
#* @post /predict
function(req, res) {
  req$.handler_started <- TRUE

  body <- req$bodyRaw
  if (is.null(body) || length(body) == 0) {
    res$status <- 400L
    return(list(error = "Пустое тело запроса. Ожидается JSON.", details = list()))
  }
  if (length(body) > MAX_BODY_BYTES) {
    res$status <- 413L
    return(list(error = "Слишком большое тело запроса.", details = list()))
  }

  text <- rawToChar(body)
  Encoding(text) <- "UTF-8"
  parsed <- tryCatch(jsonlite::fromJSON(text, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(parsed)) {
    res$status <- 400L
    return(list(error = "Некорректный JSON в теле запроса.", details = list()))
  }

  check <- validate_features(parsed, SPEC)
  if (!check$ok) {
    res$status <- 422L
    return(list(error = "Некорректные входные данные.", details = unname(check$errors)))
  }

  prob <- predict_churn_prob(BUNDLE, check$data)
  klass <- if (prob >= BUNDLE$threshold) POSITIVE_CLASS else NEGATIVE_CLASS

  list(
    prediction = list(
      class = klass,
      label = unname(CLASS_LABELS_RU[klass]),
      is_churn_likely = identical(klass, POSITIVE_CLASS),
      churn_probability = round(prob, 4),
      churn_probability_percent = round(100 * prob, 1),
      threshold = BUNDLE$threshold
    ),
    model = list(name = BUNDLE$model_name, label = BUNDLE$model_label),
    warnings = as.list(check$warnings),
    disclaimer = DISCLAIMER_RU
  )
}
